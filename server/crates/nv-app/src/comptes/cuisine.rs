//! Les lectures et écritures des comptes et des profils.
use serde_json::Value;
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// Un profil porte déjà ce nom (sans tenir compte des majuscules).
pub async fn username_pris(db: &mut PgConnection, nom: &str) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.profiles
                           where lower(display_name) = lower($1)) as "b!""#,
        nom
    )
    .fetch_one(db)
    .await?)
}

/// Ma suspension, s'il y en a une (`[]` sinon).
pub async fn ma_suspension(db: &mut PgConnection, moi: Uuid) -> NvResult<Value> {
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!"
             from (select p.suspended_at, p.suspended_reason as reason
                     from public.profiles p
                    where p.id = $1 and p.suspended_at is not null) t"#,
        moi
    )
    .fetch_one(db)
    .await?)
}

/// Les chiffres d'un profil : amis, publications, Vibes de la semaine.
pub async fn chiffres_du_profil(db: &mut PgConnection, cible: Uuid) -> NvResult<Value> {
    Ok(sqlx::query_scalar!(
        r#"select json_build_array(json_build_object(
             'friends', (select count(*)::integer from public.connections
                          where (user_low = $1 or user_high = $1) and status = 'full'),
             'posts', (select count(*)::integer from public.library_items where owner_id = $1),
             'cards_week', (
               (select count(*) from public.cards c
                 where c.owner_id = $1
                   and c.created_at > now() - interval '7 days'
                   and exists (select 1 from public.card_deliveries d where d.card_id = c.id))
               + (select count(*) from public.contents ct
                   where ct.owner_id = $1
                     and ct.created_at > now() - interval '7 days'))::integer
           )) as "j!""#,
        cible
    )
    .fetch_one(db)
    .await?)
}

// ─── Les profils (ce que l'app lisait et écrivait directement) ─────────────

/// La ligne complète des profils demandés (ceux que la règle d'accès laisse
/// voir ont déjà été choisis par l'appelant).
///
/// ⚠️ **Écart voulu** (2026-09-27) : la suspension d'un autre compte que le
/// mien (`suspended_at`, `suspended_reason`) est masquée. L'ancien guichet
/// la donnait à quiconque voyait le profil ; l'app ne s'en sert pas
/// (seule ma propre suspension compte, via `my_suspension`).
pub async fn profils(db: &mut PgConnection, moi: Option<Uuid>, ids: &[Uuid]) -> NvResult<Value> {
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(to_jsonb(p) || case when p.id is distinct from $1
                    then '{"suspended_at": null, "suspended_reason": null}'::jsonb
                    else '{}'::jsonb end), '[]'::json) as "j!"
             from public.profiles p where p.id = any($2)"#,
        moi,
        ids
    )
    .fetch_one(db)
    .await?)
}

/// Crée mon profil.
pub async fn creer_profil(db: &mut PgConnection, moi: Uuid, nom: &str, pseudo: Option<&str>) -> NvResult<()> {
    sqlx::query!(
        "insert into public.profiles (id, display_name, tag_name) values ($1, $2, $3)",
        moi,
        nom,
        pseudo
    )
    .execute(db)
    .await
    .map_err(|e| nv_core::contrainte::traduire(e, CONTRAINTES_PROFIL))?;
    Ok(())
}

/// Les phrases des protections de la table `profiles`.
pub const CONTRAINTES_PROFIL: &[(&str, &str)] = &[
    ("profiles_username_unique", "Ce nom est déjà pris."),
    ("profiles_pkey", "Ton profil existe déjà."),
    ("profiles_display_name_check", "Nom invalide : 3 à 20 caractères, minuscules, chiffres, point ou tiret bas."),
    ("profiles_tag_name_check", "Le pseudo doit faire de 1 à 30 caractères."),
    ("profiles_bio_check", "La bio ne peut pas dépasser 500 caractères."),
    ("profiles_special_mention_check", "La mention ne peut pas dépasser 90 caractères."),
];

/// Une valeur de colonne modifiable de mon profil.
pub enum ValeurProfil {
    Texte(Option<String>),
    Booleen(bool),
    Visibilite(String),
}

/// Modifie des colonnes de mon profil (déjà choisies et vérifiées par le
/// guichet : seules les colonnes ouvertes à l'app arrivent ici).
pub async fn modifier_profil(db: &mut PgConnection, moi: Uuid, colonnes: &[(&'static str, ValeurProfil)]) -> NvResult<()> {
    if colonnes.is_empty() {
        return Ok(());
    }
    let mut q = sqlx::QueryBuilder::new("update public.profiles set ");
    for (i, (col, v)) in colonnes.iter().enumerate() {
        if i > 0 {
            q.push(", ");
        }
        q.push(*col).push(" = ");
        match v {
            ValeurProfil::Texte(t) => q.push_bind(t.clone()),
            ValeurProfil::Booleen(b) => q.push_bind(*b),
            ValeurProfil::Visibilite(s) => q.push_bind(s.clone()).push("::public.library_visibility"),
        };
    }
    q.push(" where id = ").push_bind(moi);
    q.build().execute(db).await.map_err(|e| nv_core::contrainte::traduire(e, CONTRAINTES_PROFIL))?;
    Ok(())
}

/// Dépose un rapport de diagnostic (outil de développement).
#[allow(clippy::too_many_arguments)]
pub async fn deposer_rapport(
    db: &mut PgConnection,
    moi: Uuid,
    kind: &str,
    app_version: Option<&str>,
    device: Option<&str>,
    note: Option<&str>,
    body: Option<&str>,
    data: Option<&Value>,
) -> NvResult<()> {
    sqlx::query!(
        "insert into public.dev_reports (author_id, kind, app_version, device, note, body, data)
         values ($1, $2, $3, $4, $5, $6, $7)",
        moi,
        kind,
        app_version,
        device,
        note,
        body,
        data
    )
    .execute(db)
    .await?;
    Ok(())
}
