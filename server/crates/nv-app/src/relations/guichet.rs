//! Les guichets des relations et de la proximité.
//!
//! Chaque opération suit pas à pas l'ancienne fonction du même nom (mêmes
//! vérifications, dans le même ordre, mêmes messages) ; ce que faisaient ses
//! déclencheurs est fait ici, explicitement.
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use super::regles::{creneau, plausible, PLAFOND_RECOMMANDATIONS_MOIS};
use super::{cuisine, paliers, rencontres};
use crate::acces::{self, q};
use crate::comptes::cuisine::profil_vu;
use crate::carte::positions;

ops![
    publish_ping_beacon => publish_ping_beacon,
    retire_ping_beacon => retire_ping_beacon,
    confirm_ping => confirm_ping,
    ping_nearby => ping_nearby,
    ping_neighbour_count => ping_neighbour_count,
    report_sightings => report_sightings,
    crossed_recently => crossed_recently,
    request_connection_from_proximity => request_connection_from_proximity,
    accept_connection_request => accept_connection_request,
    decline_connection_request => decline_connection_request,
    my_friendships => my_friendships,
    block_user => block_user,
    unblock_user => unblock_user,
    accept_recommendation => accept_recommendation,
    decline_recommendation => decline_recommendation,
    forward_recommendation => forward_recommendation,
    device_key_upsert => device_key_upsert,
    key_book_list => key_book_list,
    connection_delete => connection_delete,
    connection_requests_history => connection_requests_history,
    recommendations_list => recommendations_list,
    recommendation_create => recommendation_create,
    blocks_list => blocks_list,
    waves_list => waves_list,
    wave_insert => wave_insert,
];

fn non_authentifie(ctx: &Ctx, message: &'static str) -> NvResult<Uuid> {
    ctx.actor.uid().map_err(|_| NvError::refused(message))
}

// ─── Le ping ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Balise {
    p_lat: Option<f64>,
    p_lon: Option<f64>,
    p_token: Option<String>,
    p_slot: i64,
    #[serde(default)]
    p_acc: Option<f64>,
}

/// `publish_ping_beacon` : ma balise (et, si je partage, ma position pour
/// mes amis — au plus toutes les 30 minutes).
async fn publish_ping_beacon(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifié")?;
    let a: Balise = parse(args)?;
    let jeton = a.p_token.filter(|t| !t.is_empty()).ok_or_else(|| NvError::refused("Jeton manquant"))?;
    let (lat, lon) = match (a.p_lat, a.p_lon) {
        (Some(la), Some(lo)) if (-90.0..=90.0).contains(&la) && (-180.0..=180.0).contains(&lo) => (la, lo),
        _ => return Err(NvError::refused("Position hors bornes")),
    };
    let acc = Some(a.p_acc.unwrap_or(0.0));
    cuisine::deposer_balise(ctx.db(), moi, lat, lon, acc, &jeton, a.p_slot).await?;
    positions::enregistrer(ctx.db(), moi, lat, lon, acc, false).await?;
    Ok(Value::Null)
}

async fn retire_ping_beacon(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    parse::<NoArgs>(args)?;
    if let Some(moi) = ctx.actor.maybe_uid() {
        cuisine::retirer_balise(ctx.db(), moi).await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Confirmation {
    p_tokens: Option<Vec<String>>,
    p_slot: i64,
}

/// `confirm_ping` : les jetons que j'ai entendus. Une PAIRE ne naît que si
/// l'autre m'a entendu aussi (le miroir) — et c'est alors que la rencontre
/// se note (ex-déclencheur `on_ping_pair_born`).
async fn confirm_ping(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifié")?;
    let a: Confirmation = parse(args)?;
    let maintenant = creneau(ctx.now.timestamp());
    // Anti-antidatage : ni futur, ni plus d'une heure.
    if a.p_slot > maintenant + 1 || a.p_slot < maintenant - 4 {
        return Ok(json!(0));
    }
    // On n'écoute que si on s'annonce.
    let Some(mon_carreau) = cuisine::mon_carreau(ctx.db(), moi).await? else { return Ok(json!(0)) };
    let mut retenus = 0;
    for jeton in a.p_tokens.unwrap_or_default() {
        let Some((sujet, s_lat, s_lon)) = cuisine::porteur_du_jeton(ctx.db(), &jeton, a.p_slot).await? else { continue };
        if sujet == moi || acces::is_blocked(ctx.db(), moi, sujet).await? || !plausible(mon_carreau, (s_lat, s_lon)) {
            continue;
        }
        retenus += cuisine::noter_confirmation(ctx.db(), moi, sujet, a.p_slot).await?;
        if cuisine::miroir(ctx.db(), moi, sujet, a.p_slot).await? {
            let (bas, haut) = (moi.min(sujet), moi.max(sujet));
            if let Some(nee) = cuisine::paire_vue(ctx.db(), bas, haut).await? {
                rencontres::noter(ctx.db(), bas, haut, rencontres::Rencontre { origine: "ping", soiree: None, lieu: None, quand: nee })
                    .await?;
            }
        }
    }
    Ok(json!(retenus))
}

/// `ping_nearby` : ceux que j'ai croisés en ping ces dix dernières minutes
/// (ni amis, ni bloqués).
async fn ping_nearby(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifie")?;
    parse::<NoArgs>(args)?;
    let filtre = format!("not {} and not {}", q::sont_amis("$1::uuid", "p.id"), q::est_bloque("$1::uuid", "p.id"));
    cuisine::autour_de_moi(ctx.db(), moi, &filtre).await
}

/// `ping_neighbour_count` : combien de balises vivantes autour de moi.
async fn ping_neighbour_count(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifié")?;
    parse::<NoArgs>(args)?;
    let Some(c) = cuisine::mon_carreau(ctx.db(), moi).await? else { return Ok(json!(0)) };
    let n = cuisine::voisins(ctx.db(), moi, c, &q::est_bloque("$1::uuid", "b.user_id")).await?;
    Ok(json!(n))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Vues {
    items: Value,
}

/// `report_sightings` : ceux que j'ai reconnus au Bluetooth. Entre amis, un
/// croisement MUTUEL inscrit un jour de rencontre (et recalcule le palier) ;
/// entre co-présents d'une soirée ouverte, il inscrit un croisement en
/// soirée (et la rencontre, ex-déclencheur `on_event_crossing_born`).
async fn report_sightings(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifie")?;
    let a: Vues = parse(args)?;
    let maintenant = creneau(ctx.now.timestamp());
    let items = match a.items {
        Value::Array(v) => v,
        Value::Null => vec![],
        _ => return Err(NvError::BadArgs("items : une liste est attendue".into())),
    };
    let mut retenus = 0;
    for item in items {
        let texte = |k: &str| item.get(k).and_then(|v| match v {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        });
        // Un identifiant ou un créneau illisible fait échouer tout l'envoi,
        // comme avant (conversion SQL refusée).
        let pair = match texte("peer") {
            None => None,
            Some(s) => Some(Uuid::parse_str(&s).map_err(|_| NvError::BadArgs("peer illisible".into()))?),
        };
        let s = match texte("slot") {
            None => None,
            Some(s) => Some(s.parse::<i64>().map_err(|_| NvError::BadArgs("slot illisible".into()))?),
        };
        let (Some(pair), Some(s)) = (pair, s) else { continue };
        if pair == moi || s > maintenant + 1 || s < maintenant - (48 * 3600 / super::regles::CRENEAU_S) {
            continue;
        }
        let bande = texte("band");
        if acces::sont_amis(ctx.db(), moi, pair).await? {
            retenus += cuisine::noter_vu(ctx.db(), moi, pair, s, bande.as_deref()).await?;
            if cuisine::vu_en_retour(ctx.db(), moi, pair, s).await? {
                let (bas, haut) = (moi.min(pair), moi.max(pair));
                if cuisine::croisement_amis(ctx.db(), bas, haut).await? {
                    paliers::recalculer(ctx.db(), bas, haut).await?;
                }
            }
            continue;
        }
        let Some((soiree, titre)) = cuisine::soiree_commune(ctx.db(), moi, pair).await? else { continue };
        retenus += cuisine::noter_vu_en_soiree(ctx.db(), soiree, moi, pair, s).await?;
        if cuisine::vu_en_retour_en_soiree(ctx.db(), soiree, moi, pair, s).await? && !acces::is_blocked(ctx.db(), moi, pair).await? {
            let (bas, haut) = (moi.min(pair), moi.max(pair));
            if let Some(nee) = cuisine::croisement_en_soiree(ctx.db(), soiree, &titre, bas, haut).await? {
                rencontres::croisement_en_soiree(ctx.db(), soiree, bas, haut, Some(&titre), nee).await?;
            }
        }
    }
    Ok(json!(retenus))
}

/// `crossed_recently` : ceux que j'ai croisés (ping ou soirée) dans leur
/// fenêtre, le plus récent d'abord.
async fn crossed_recently(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifié")?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "with croisements as (
           select case when pp.user_low = $1 then pp.user_high else pp.user_low end as autre,
                  pp.last_seen_at as quand, 'ping'::text as orig, null::text as titre
             from public.ping_pairs pp
            where (pp.user_low = $1 or pp.user_high = $1) and pp.last_seen_at > now() - {fp}
           union all
           select case when c.user_low = $1 then c.user_high else c.user_low end, c.last_at, 'event', c.event_title
             from public.event_crossings c
            where (c.user_low = $1 or c.user_high = $1) and c.last_at > now() - {fe}
         ), dernier as (
           select distinct on (autre) autre, quand, orig, titre from croisements order by autre, quand desc
         )
         select coalesce(json_agg(t order by t.crossed_at desc), '[]'::json) from (
           select p.id as user_id, p.display_name, p.pseudo_shown as tag_name, p.avatar_url, d.quand as crossed_at,
                  exists (select 1 from public.connection_requests r where r.sender_id = $1 and r.receiver_id = p.id
                            and r.status = 'pending' and r.expires_at > now()) as already_requested,
                  d.orig as origin, d.titre as event_title
             from dernier d join public.profiles p on p.id = d.autre
            where not {amis} and not {bloque}) t",
        fp = q::fenetre("ping"),
        fe = q::fenetre("event"),
        amis = q::sont_amis("$1::uuid", "p.id"),
        bloque = q::est_bloque("$1::uuid", "p.id"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

// ─── Les demandes d'ami ────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Pair {
    peer: Option<Uuid>,
}

/// `request_connection_from_proximity` : la barrière fondatrice — une
/// demande d'ami n'existe qu'après un ping MUTUEL récent.
async fn request_connection_from_proximity(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifié")?;
    let a: Pair = parse(args)?;
    let pair = a.peer.filter(|p| *p != moi).ok_or_else(|| NvError::refused("Destinataire invalide"))?;
    if acces::is_blocked(ctx.db(), moi, pair).await? {
        return Err(NvError::refused("Demande impossible"));
    }
    if acces::sont_amis(ctx.db(), moi, pair).await? {
        return Err(NvError::refused("Vous êtes déjà connectés"));
    }
    let sql = format!(
        "select exists (select 1 from public.ping_pairs pp
                         where ((pp.user_low = $1 and pp.user_high = $2) or (pp.user_low = $2 and pp.user_high = $1))
                           and pp.last_seen_at > now() - {})",
        super::regles::FENETRE_RENCONTRE
    );
    let constatee = sqlx::query_scalar::<_, bool>(&sql).bind(moi).bind(pair).fetch_one(ctx.db()).await?;
    if !constatee {
        return Err(NvError::refused("Proximité non constatée"));
    }
    let deja = sqlx::query_scalar!(
        "select id from public.connection_requests
          where sender_id = $1 and receiver_id = $2 and status = 'pending' and expires_at > now() limit 1",
        moi,
        pair
    )
    .fetch_optional(ctx.db())
    .await?;
    if let Some(id) = deja {
        return Ok(json!(id));
    }
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let id = sqlx::query_scalar!(
        "insert into public.connection_requests (sender_id, receiver_id, status, expires_at)
         values ($1, $2, 'pending', now() + interval '7 days') returning id",
        moi,
        pair
    )
    .fetch_one(ctx.db())
    .await?;
    Ok(json!(id))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Demande {
    req_id: Uuid,
}

/// `accept_connection_request` : le destinataire accepte ; le lien s'établit.
async fn accept_connection_request(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Demande = parse(args)?;
    let r = sqlx::query!(
        r#"select sender_id, receiver_id, status::text as "status!", expires_at < now() as "expiree!"
             from public.connection_requests where id = $1 for update"#,
        a.req_id
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Demande introuvable"))?;
    if Some(r.receiver_id) != ctx.actor.maybe_uid() {
        return Err(NvError::refused("Seul le destinataire peut accepter"));
    }
    if r.status != "pending" || r.expiree {
        return Err(NvError::refused("Demande expirée"));
    }
    if acces::is_blocked(ctx.db(), r.sender_id, r.receiver_id).await? {
        return Err(NvError::refused("Demande impossible"));
    }
    sqlx::query!("update public.connection_requests set status = 'accepted' where id = $1", a.req_id)
        .execute(ctx.db())
        .await?;
    let lien = cuisine::etablir_lien(ctx.db(), r.sender_id, r.receiver_id, "proximity").await?;
    Ok(json!(lien))
}

/// `decline_connection_request` : le destinataire refuse (sans bruit).
async fn decline_connection_request(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Demande = parse(args)?;
    sqlx::query!(
        "update public.connection_requests set status = 'declined'
          where id = $1 and receiver_id = $2 and status = 'pending'",
        a.req_id,
        ctx.actor.maybe_uid()
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `my_friendships` : mes liens établis, leur palier et leur série.
async fn my_friendships(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    parse::<NoArgs>(args)?;
    let Some(moi) = ctx.actor.maybe_uid() else { return Ok(json!([])) };
    let sql = format!(
        "select coalesce(json_agg(t), '[]'::json) from (
           select case when c.user_low = $1 then c.user_high else c.user_low end as peer_id,
                  c.tier, c.tier_days, {suivant} as days_to_next, {serie} as streak
             from public.connections c
            where $1 in (c.user_low, c.user_high) and c.status = 'full') t",
        suivant = paliers::jours_avant_suivant("c.tier_days"),
        serie = paliers::serie("c.user_low", "c.user_high"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

// ─── Les blocages ──────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cible {
    p_user_id: Option<Uuid>,
}

/// `block_user` : bloquer coupe TOUT ce qui reliait les deux — le lien, les
/// demandes, l'accès à la bibliothèque, les paires et confirmations de ping,
/// et ce qui dérivait du lien.
async fn block_user(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx, "Non authentifié")?;
    let a: Cible = parse(args)?;
    let autre = a.p_user_id.filter(|u| *u != moi).ok_or_else(|| NvError::refused("Destinataire invalide"))?;
    let db = ctx.db();
    sqlx::query!("insert into public.blocks (blocker_id, blocked_id) values ($1, $2) on conflict do nothing", moi, autre)
        .execute(&mut *db)
        .await?;
    let liens = sqlx::query!(
        "delete from public.connections c where c.user_low = least($1::uuid, $2::uuid) and c.user_high = greatest($1::uuid, $2::uuid)",
        moi,
        autre
    )
    .execute(&mut *db)
    .await?
    .rows_affected();
    if liens > 0 {
        cuisine::oublier_le_lien(db, moi, autre).await?;
    }
    sqlx::query!(
        "delete from public.connection_requests r where (r.sender_id = $1 and r.receiver_id = $2) or (r.sender_id = $2 and r.receiver_id = $1)",
        moi,
        autre
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "delete from public.library_access la where (la.owner_id = $1 and la.grantee_id = $2) or (la.owner_id = $2 and la.grantee_id = $1)",
        moi,
        autre
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "delete from public.ping_pairs pp where pp.user_low = least($1::uuid, $2::uuid) and pp.user_high = greatest($1::uuid, $2::uuid)",
        moi,
        autre
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "delete from public.ping_confirmations pc where (pc.observer_id = $1 and pc.subject_id = $2) or (pc.observer_id = $2 and pc.subject_id = $1)",
        moi,
        autre
    )
    .execute(db)
    .await?;
    Ok(Value::Null)
}

async fn unblock_user(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Cible = parse(args)?;
    sqlx::query!("delete from public.blocks where blocker_id = $1 and blocked_id = $2", ctx.actor.maybe_uid(), a.p_user_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

// ─── Les recommandations ───────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reco {
    reco_id: Uuid,
}

/// `accept_recommendation` : la personne recommandée accepte.
async fn accept_recommendation(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Reco = parse(args)?;
    let r = sqlx::query!(
        r#"select requester_id, target_id, status::text as "status!", expires_at < now() as "expiree!"
             from public.recommendations where id = $1 for update"#,
        a.reco_id
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Recommandation introuvable"))?;
    let (Some(cible), Some(moi)) = (r.target_id, ctx.actor.maybe_uid()) else {
        return Err(NvError::refused("Seul le destinataire peut accepter"));
    };
    if cible != moi {
        return Err(NvError::refused("Seul le destinataire peut accepter"));
    }
    if r.status != "forwarded" || r.expiree {
        return Err(NvError::refused("Proposition expirée"));
    }
    if acces::is_blocked(ctx.db(), r.requester_id, cible).await? {
        return Err(NvError::refused("Mise en relation impossible"));
    }
    sqlx::query!("update public.recommendations set status = 'accepted', resolved_at = now() where id = $1", a.reco_id)
        .execute(ctx.db())
        .await?;
    let lien = cuisine::etablir_lien(ctx.db(), r.requester_id, cible, "recommendation").await?;
    Ok(json!(lien))
}

async fn decline_recommendation(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Reco = parse(args)?;
    sqlx::query!(
        "update public.recommendations set status = 'declined', resolved_at = now()
          where id = $1 and (intermediary_id = $2 or target_id = $2) and status in ('requested', 'forwarded')",
        a.reco_id,
        ctx.actor.maybe_uid()
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Transmission {
    reco_id: Uuid,
    chosen_target: Option<Uuid>,
}

/// `forward_recommendation` : l'intermédiaire choisit la personne à
/// présenter (10 mises en relation par mois au plus).
async fn forward_recommendation(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Transmission = parse(args)?;
    let r = sqlx::query!(
        r#"select requester_id, intermediary_id, status::text as "status!", expires_at < now() as "expiree!"
             from public.recommendations where id = $1 for update"#,
        a.reco_id
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Recommandation introuvable"))?;
    let moi = ctx.actor.maybe_uid();
    if Some(r.intermediary_id) != moi {
        return Err(NvError::refused("Seul l'intermédiaire peut transmettre"));
    }
    let moi = r.intermediary_id;
    if r.status != "requested" || r.expiree {
        return Err(NvError::refused("Demande expirée ou déjà traitée"));
    }
    let cible = a.chosen_target;
    if cible == Some(r.requester_id) || cible == Some(r.intermediary_id) {
        return Err(NvError::refused("Destinataire invalide"));
    }
    let Some(cible) = cible else { return Err(NvError::refused("Vous devez être connecté à la personne choisie")) };
    if !acces::sont_amis(ctx.db(), moi, cible).await? {
        return Err(NvError::refused("Vous devez être connecté à la personne choisie"));
    }
    if acces::sont_amis(ctx.db(), r.requester_id, cible).await? {
        return Err(NvError::refused("Ces personnes sont déjà connectées"));
    }
    if acces::is_blocked(ctx.db(), r.requester_id, cible).await? || acces::is_blocked(ctx.db(), moi, cible).await? {
        return Err(NvError::refused("Mise en relation impossible"));
    }
    let ce_mois = sqlx::query_scalar!(
        r#"select count(*) as "n!" from public.recommendations
            where intermediary_id = $1 and forwarded_at >= date_trunc('month', now())"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if ce_mois >= PLAFOND_RECOMMANDATIONS_MOIS {
        return Err(NvError::refused("Plafond mensuel de 10 mises en relation atteint"));
    }
    sqlx::query!(
        "update public.recommendations set target_id = $2, status = 'forwarded', forwarded_at = now(),
                expires_at = now() + interval '14 days' where id = $1",
        a.reco_id,
        cible
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

// ─── Ce que l'app faisait directement sur les tables ───────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cle {
    user_id: Uuid,
    x25519_pub: String,
}

/// `device_key_upsert` : ma clé de reconnaissance (ex-`device_keys.upsert`).
async fn device_key_upsert(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Cle = parse(args)?;
    if a.user_id != moi {
        return Err(NvError::refused("On ne publie que sa propre clé."));
    }
    sqlx::query!(
        "insert into public.device_keys (user_id, x25519_pub) values ($1, $2)
         on conflict (user_id) do update set x25519_pub = excluded.x25519_pub",
        moi,
        a.x25519_pub
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `key_book_list` : le carnet des clés que je peux reconnaître — mes amis
/// (`friend`) et les co-présents d'une soirée (`event`), jamais les autres
/// (ex-vue `key_book` et sa règle `relation_kind`).
async fn key_book_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "select coalesce(json_agg(t), '[]'::json) from (
           select k.user_id, k.x25519_pub, k.updated_at, {rel} as relation
             from public.device_keys k
            where k.user_id <> $1 and {rel} is not null) t",
        rel = q::relation("$1::uuid", "k.user_id")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnLien {
    id: Uuid,
}

/// `connection_delete` : retirer un ami (ex-`connections.delete().eq('id', …)`) ;
/// ce qui dérivait du lien disparaît avec lui.
async fn connection_delete(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnLien = parse(args)?;
    let parti = sqlx::query!(
        "delete from public.connections where id = $1 and ($2 = user_low or $2 = user_high) returning user_low, user_high",
        a.id,
        moi
    )
    .fetch_optional(ctx.db())
    .await?;
    if let Some(l) = parti {
        cuisine::oublier_le_lien(ctx.db(), l.user_low, l.user_high).await?;
    }
    Ok(Value::Null)
}

/// `connection_requests_history` : mes 50 dernières demandes, reçues et
/// envoyées.
async fn connection_requests_history(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!" from (
             select * from public.connection_requests r where $1 = r.sender_id or $1 = r.receiver_id
              order by r.created_at desc limit 50) t"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RoleReco {
    p_role: String,
}

/// `recommendations_list` : les recommandations où je suis demandeur, ou
/// intermédiaire (à traiter), ou destinataire (proposées), avec les trois
/// profils — chacun visible selon la règle des profils.
async fn recommendations_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: RoleReco = parse(args)?;
    let filtre = match a.p_role.as_str() {
        "requester" => "r.requester_id = $1",
        "intermediary" => "r.intermediary_id = $1 and r.status = 'requested'",
        "target" => "r.target_id = $1 and r.status = 'forwarded'",
        _ => return Err(NvError::BadArgs("p_role : requester, intermediary ou target".into())),
    };
    let profil = |col: &str| {
        format!(
            "(select {vu} from public.profiles p where p.id = r.{col} and {voit})",
            vu = profil_vu("p", "$1::uuid"),
            voit = q::peut_voir_profil("$1::uuid", "p.id")
        )
    };
    let sql = format!(
        "select coalesce(json_agg(t order by t.created_at desc), '[]'::json) from (
           select r.*, {req} as requester, {inter} as intermediary, {cible} as target
             from public.recommendations r where {filtre}) t",
        req = profil("requester_id"),
        inter = profil("intermediary_id"),
        cible = profil("target_id"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NouvelleReco {
    requester_id: Uuid,
    intermediary_id: Uuid,
    target_hint: Option<String>,
}

/// `recommendation_create` : je demande à un ami de me présenter quelqu'un
/// (décrit en texte libre).
async fn recommendation_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: NouvelleReco = parse(args)?;
    if a.requester_id != moi || !acces::sont_amis(ctx.db(), moi, a.intermediary_id).await? {
        return Err(NvError::refused("Demande de mise en relation refusée."));
    }
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    sqlx::query!(
        "insert into public.recommendations (requester_id, intermediary_id, target_hint) values ($1, $2, $3)",
        moi,
        a.intermediary_id,
        a.target_hint
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `blocks_list` : ceux que j'ai bloqués, avec leur profil.
async fn blocks_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "select coalesce(json_agg(t order by t.created_at desc), '[]'::json) from (
           select b.blocked_id, b.created_at,
                  (select {vu} from public.profiles p where p.id = b.blocked_id and {voit}) as profiles
             from public.blocks b where b.blocker_id = $1) t",
        vu = profil_vu("p", "$1::uuid"),
        voit = q::peut_voir_profil("$1::uuid", "p.id")
    );
    let v = sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?;
    // L'app ne lit que `blocked_id` et `profiles` : `created_at` servait au tri.
    Ok(match v {
        Value::Array(l) => Value::Array(
            l.into_iter()
                .map(|mut x| {
                    if let Some(o) = x.as_object_mut() {
                        o.remove("created_at");
                    }
                    x
                })
                .collect(),
        ),
        autre => autre,
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Saluts {
    p_before: Option<chrono::DateTime<chrono::Utc>>,
}

/// `waves_list` : mes 50 derniers saluts à montrer (dont l'heure de
/// notification est passée).
async fn waves_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Saluts = parse(args)?;
    let avant = a.p_before.unwrap_or(ctx.now);
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!" from (
             select * from public.waves w where w.user_id = $1 and w.notify_after <= $2
              order by w.detected_at desc limit 50) t"#,
        moi,
        avant
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Salut {
    user_id: Uuid,
    peer_id: Uuid,
    notify_after: Option<chrono::DateTime<chrono::Utc>>,
}

/// `wave_insert` : un salut envoyé à un ami croisé.
async fn wave_insert(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Salut = parse(args)?;
    if a.user_id != moi || !acces::sont_amis(ctx.db(), moi, a.peer_id).await? {
        return Err(NvError::refused("Salut refusé."));
    }
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    match a.notify_after {
        Some(n) => sqlx::query!("insert into public.waves (user_id, peer_id, notify_after) values ($1, $2, $3)", moi, a.peer_id, n)
            .execute(ctx.db())
            .await?,
        None => sqlx::query!("insert into public.waves (user_id, peer_id) values ($1, $2)", moi, a.peer_id).execute(ctx.db()).await?,
    };
    Ok(Value::Null)
}
