//! Jouer une situation des deux côtés, dans une seule transaction.
use std::collections::{HashMap, HashSet};

use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool, Row};

use nv_core::ops::OpFn;
use nv_core::{Actor, Ctx, NvError};

use crate::cas::Cas;
use crate::compare::{self, Issue};

/// Les déclencheurs de l'ANCIEN GARDIEN : des règles du produit, traduites
/// en Rust, qui disparaîtront avec lui. Le nouveau côté les coupe.
///
/// Ne sont PAS dans cette liste les **fondations**, qui restent dans la base
/// parce qu'elles doivent voir tous les chemins, effacements en cascade
/// compris (docs/serveur-rust.md) : l'horodatage des profils
/// (`profiles_updated_at`), les pierres tombales des fichiers
/// (`*_octets_a_supprimer`, `events_affiche_au_balai`), l'annonce des
/// disparitions (`*_annonce_disparition`), l'activité des conversations
/// (`messages_activity`), et les annonces du direct et de la preuve.
// (La libération des preuves, `*_libere`, n'y est pas : c'est une
// FONDATION — elle doit voir la disparition d'un signalement par cascade.)
pub const DECLENCHEURS_DU_GARDIEN: &[(&str, &str)] = &[
    ("public.messages", "messages_rules"),
    ("public.card_deliveries", "card_deliveries_rules"),
    ("public.cards", "cards_refuse_si_suspendu"),
    ("public.connection_requests", "connection_requests_refuse_si_suspendu"),
    ("public.content_likes", "content_likes_refuse_si_suspendu"),
    ("public.recommendations", "recommendations_refuse_si_suspendu"),
    ("public.waves", "waves_refuse_si_suspendu"),
    ("public.card_reports", "card_reports_scelle"),
    ("public.content_reports", "content_reports_scelle"),
    ("public.event_reports", "event_reports_scelle"),
    ("public.library_vibe_reports", "library_vibe_reports_scelle"),
    ("public.connections", "connections_delete_oublie"),
    ("public.ping_pairs", "ping_pairs_meeting"),
    ("public.event_crossings", "event_crossings_meeting"),
    ("auth.users", "record_device_signup"),
];

/// Une ligne du journal des changements.
#[derive(Debug, Clone)]
pub struct Change {
    pub tbl: String,
    pub op: String,
    pub old: Value,
    pub new: Value,
}

/// Ce qu'un côté a produit.
#[derive(Debug)]
pub struct Cote {
    pub issue: Issue,
    pub changes: Vec<Change>,
}

/// Les colonnes remplies par un compteur (`nextval`, identité) : leurs
/// valeurs diffèrent forcément d'un côté à l'autre, on ne les compare pas.
pub async fn colonnes_de_serie(pool: &PgPool) -> Result<HashSet<(String, String)>, String> {
    let rows = sqlx::query(
        "select table_schema || '.' || table_name as t, column_name as c
           from information_schema.columns
          where (column_default like 'nextval(%' or is_identity = 'YES')
            and table_schema in ('public', 'private', 'nv', 'auth', 'storage')",
    )
    .fetch_all(pool)
    .await
    .map_err(|e| e.to_string())?;
    Ok(rows.iter().map(|r| (r.get::<String, _>("t"), r.get::<String, _>("c"))).collect())
}

async fn lire_journal(db: &mut PgConnection) -> Result<Vec<Change>, String> {
    let rows = sqlx::query(
        "select tbl, op, coalesce(old, 'null'::jsonb) as old, coalesce(new, 'null'::jsonb) as new
           from nv_proof.changes order by n",
    )
    .fetch_all(db)
    .await
    .map_err(|e| format!("journal : {e}"))?;
    Ok(rows
        .iter()
        .map(|r| Change {
            tbl: r.get("tbl"),
            op: r.get("op"),
            old: r.get("old"),
            new: r.get("new"),
        })
        .collect())
}

async fn exec(db: &mut PgConnection, sql: &str) -> Result<(), String> {
    sqlx::raw_sql(sql).execute(db).await.map(|_| ()).map_err(|e| format!("{sql} : {e}"))
}

/// Construit l'appel SQL d'une fonction `public.<nom>` avec les arguments
/// JSON, comme le guichet de Supabase le faisait (arguments nommés).
async fn appel_sql(db: &mut PgConnection, nom: &str, args: &Value) -> Result<(String, bool), String> {
    let rows = sqlx::query(
        "select pg_get_function_identity_arguments(p.oid) as ids, p.proretset as setof,
                p.prorettype = 'void'::regtype as vide
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = $1",
    )
    .bind(nom)
    .fetch_all(&mut *db)
    .await
    .map_err(|e| e.to_string())?;
    let cles: HashSet<String> = args.as_object().map(|o| o.keys().cloned().collect()).unwrap_or_default();
    // (paramètres, renvoie un ensemble, ne renvoie rien)
    type Signature = (Vec<(String, String)>, bool, bool);
    let mut choix: Option<Signature> = None;
    for r in rows {
        let ids: String = r.get("ids");
        let params: Vec<(String, String)> = if ids.trim().is_empty() {
            vec![]
        } else {
            ids.split(", ")
                .map(|p| {
                    let (n, t) = p.split_once(' ').unwrap_or((p, "text"));
                    (n.to_string(), t.to_string())
                })
                .collect()
        };
        let noms: HashSet<String> = params.iter().map(|p| p.0.clone()).collect();
        if cles.is_subset(&noms)
            && choix.as_ref().is_none_or(|(c, _, _)| params.len() < c.len())
        {
            choix = Some((params, r.get("setof"), r.get("vide")));
        }
    }
    let (params, setof, vide) = choix.ok_or_else(|| format!("public.{nom} introuvable pour ces arguments"))?;
    let mut morceaux = Vec::new();
    for (n, t) in &params {
        if !cles.contains(n) {
            continue;
        }
        let expr = if t.ends_with("[]") {
            format!(
                "(case when $1::jsonb -> '{n}' = 'null'::jsonb then null else \
                 (select coalesce(array_agg(x), '{{}}') from jsonb_array_elements_text($1::jsonb -> '{n}') x) end)::{t}"
            )
        } else if t == "jsonb" || t == "json" {
            format!("($1::jsonb -> '{n}')::{t}")
        } else {
            format!("($1::jsonb ->> '{n}')::{t}")
        };
        morceaux.push(format!("{n} => {expr}"));
    }
    let appel = format!("public.\"{nom}\"({})", morceaux.join(", "));
    let sql = if vide {
        format!("select 'null'::json as j from (select {appel}) x")
    } else if setof {
        format!("select coalesce(json_agg(t), '[]'::json) as j from {appel} t")
    } else {
        format!("select to_json({appel}) as j")
    };
    Ok((sql, vide))
}

fn erreur_sql(e: &sqlx::Error) -> Issue {
    match e {
        sqlx::Error::Database(d) => Issue::Refus {
            sqlstate: d.code().map(|c| c.to_string()).unwrap_or_default(),
            message: d.message().to_string(),
        },
        autre => Issue::Refus { sqlstate: "?".into(), message: autre.to_string() },
    }
}

async fn cote_ancien(db: &mut PgConnection, c: &Cas) -> Result<Cote, String> {
    let (role, claims) = match c.qui {
        Some(id) => ("authenticated", json!({ "sub": id, "role": "authenticated" })),
        None => ("anon", json!({ "role": "anon" })),
    };
    exec(db, "savepoint ancien").await?;
    // Le serveur lui-même (un balai) : les droits du propriétaire, sans
    // identité — comme l'ancien réveil (pg_cron).
    let role = if c.systeme { "postgres" } else { role };
    exec(db, &format!("set local role {role}")).await?;
    if !c.systeme {
        sqlx::query("select set_config('request.jwt.claims', $1, true)")
            .bind(claims.to_string())
            .execute(&mut *db)
            .await
            .map_err(|e| e.to_string())?;
    }
    let issue = if c.ancien.is_some() || c.ancien_resultat.is_some() {
        let sql = c.ancien.as_deref().unwrap_or("select 1");
        match sqlx::raw_sql(sql).execute(&mut *db).await {
            Err(e) => erreur_sql(&e),
            Ok(_) => match &c.ancien_resultat {
                None => Issue::Ok(Value::Null),
                // Aucune ligne (un profil invisible…) = `null`, comme le
                // `maybeSingle()` de l'app.
                Some(q) => match sqlx::query_scalar::<_, Option<Value>>(q).fetch_optional(&mut *db).await {
                    Ok(v) => Issue::Ok(v.flatten().unwrap_or(Value::Null)),
                    Err(e) => erreur_sql(&e),
                },
            },
        }
    } else if let Some(nom) = &c.rpc {
        exec(db, "reset role").await?;
        let (sql, vide) = appel_sql(db, nom, &c.args).await?;
        exec(db, &format!("set local role {role}")).await?;
        match sqlx::query_scalar::<_, Option<Value>>(&sql).bind(&c.args).fetch_one(&mut *db).await {
            Ok(v) => Issue::Ok(if vide { Value::Null } else { v.unwrap_or(Value::Null) }),
            Err(e) => erreur_sql(&e),
        }
    } else {
        return Err("ni `ancien` ni `rpc`".into());
    };
    let changes = if matches!(issue, Issue::Ok(_)) {
        exec(db, "reset role").await?;
        lire_journal(db).await?
    } else {
        vec![]
    };
    exec(db, "rollback to savepoint ancien").await?;
    Ok(Cote { issue, changes })
}

async fn cote_nouveau(
    tx: sqlx::Transaction<'static, sqlx::Postgres>,
    registre: &HashMap<&'static str, OpFn>,
    c: &Cas,
) -> Result<(Cote, sqlx::Transaction<'static, sqlx::Postgres>), String> {
    let run = *registre.get(c.op.as_str()).ok_or_else(|| format!("opération Rust « {} » absente", c.op))?;
    let mut tx = tx;
    exec(&mut tx, "savepoint nouveau").await?;
    // ⚠️ Le nouveau gardien joue SANS les déclencheurs de l'ancien : s'il
    // oubliait une règle qu'un déclencheur portait, l'ancien la tiendrait à
    // sa place et la preuve passerait quand même — puis la règle
    // disparaîtrait avec l'ancien gardien. (Annulé au retour au point de
    // sauvegarde.)
    for (table, declencheur) in DECLENCHEURS_DU_GARDIEN {
        exec(&mut tx, &format!("alter table {table} disable trigger {declencheur}")).await?;
    }
    let actor = c.qui.map(Actor::User).unwrap_or(Actor::Anonymous);
    let affiches: std::collections::HashSet<String> =
        sqlx::query_scalar::<_, String>("select name from storage.objects where bucket_id = 'event_posters'")
            .fetch_all(&mut *tx)
            .await
            .map_err(|e| e.to_string())?
            .into_iter()
            .collect();
    let entrepot = std::sync::Arc::new(crate::factice::EntrepotFactice { affiches });
    let mut ctx = Ctx::open(tx, actor, Some(entrepot)).await.map_err(|e| e.to_string())?;
    let resultat = run(&mut ctx, c.args.clone()).await;
    let mut tx = ctx.tx;
    let cote = match resultat {
        Ok(v) => {
            exec(&mut tx, "reset role").await.ok();
            Cote { issue: Issue::Ok(v), changes: lire_journal(&mut tx).await? }
        }
        Err(NvError::Refused(m)) => Cote { issue: Issue::Refus { sqlstate: "P0001".into(), message: m }, changes: vec![] },
        Err(e) if e.refus_de_la_base() => Cote {
            issue: Issue::Refus { sqlstate: e.sqlstate().unwrap_or_default(), message: e.to_string() },
            changes: vec![],
        },
        Err(NvError::Db(e)) => Cote { issue: Issue::PanneNouveau(format!("base : {e}")), changes: vec![] },
        Err(NvError::Internal(e)) => Cote { issue: Issue::PanneNouveau(e), changes: vec![] },
        Err(autre) => Cote {
            issue: Issue::Refus { sqlstate: format!("nv:{}", autre.code()), message: autre.to_string() },
            changes: vec![],
        },
    };
    exec(&mut tx, "rollback to savepoint nouveau").await?;
    Ok((cote, tx))
}

/// Joue une situation ; renvoie la liste des différences (vide = identique).
pub async fn jouer(
    pool: &PgPool,
    registre: &HashMap<&'static str, OpFn>,
    series: &HashSet<(String, String)>,
    c: &Cas,
) -> Result<Vec<String>, String> {
    let mut tx = pool.begin().await.map_err(|e| e.to_string())?;
    exec(&mut tx, "set local nv_proof.capture = 'on'").await?;
    // `{{creneau}}`, `{{creneau-1}}`… : le créneau de ping de CETTE
    // transaction (15 minutes), pour les situations qui en dépendent.
    let creneau: i64 = sqlx::query_scalar("select floor(extract(epoch from now()) / 900)::bigint")
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
    // `{{minutes+120}}`, `{{minutes-30}}`… : l'heure de CETTE transaction,
    // décalée (une heure de fin de soirée, par exemple).
    let maintenant: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("select now()").fetch_one(&mut *tx).await.map_err(|e| e.to_string())?;
    let c = &crate::cas::avec_heure(&crate::cas::avec_creneau(c, creneau), maintenant);
    if let Some(avant) = &c.avant {
        exec(&mut tx, avant).await?;
    }
    let ancien = cote_ancien(&mut tx, c).await?;
    let (nouveau, tx) = cote_nouveau(tx, registre, c).await?;
    tx.rollback().await.map_err(|e| e.to_string())?;
    Ok(compare::verdict(c, &ancien, &nouveau, series))
}
