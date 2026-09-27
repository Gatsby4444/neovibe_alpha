//! Les guichets de la carte (docs/serveur-rust.md, annexe A.8) : la
//! position des amis, le partage, les demandes de position, les Vibes
//! autour de moi.
//!
//! **Qui voit ma position** (ex-`private.may_see_location`) : moi, ou un ami
//! non bloqué, si je partage et ne la lui cache pas — [`peut_voir_position`],
//! la seule définition.
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use super::{autour, positions};
use crate::acces::{self, q};
use crate::conversations::guichet::conversation_directe;
use crate::conversations::messages::{self, Nouveau};
use crate::vibes::publication::publication_complete;

ops![
    friends_on_map => friends_on_map,
    share_my_location => share_my_location,
    set_location_sharing => set_location_sharing,
    set_location_hidden => set_location_hidden,
    request_location => request_location,
    answer_location_request => answer_location_request,
    location_request_state => location_request_state,
    map_vibes_around => map_vibes_around,
    map_vibe_items => map_vibe_items,
    location_sharing_mine => location_sharing_mine,
    location_hidden_list => location_hidden_list,
    map_rules_walking => map_rules_walking,
];

/// `private.may_see_location(propriétaire, lecteur)`.
pub fn peut_voir_position(owner: &str, viewer: &str) -> String {
    format!(
        "({owner} = {viewer} or (exists (select 1 from public.location_sharing vl_s where vl_s.user_id = {owner} and vl_s.sharing) \
         and {amis} \
         and not exists (select 1 from public.location_hidden_from vl_h where vl_h.owner_id = {owner} and vl_h.friend_id = {viewer}) \
         and not {bloque}))",
        amis = q::sont_amis(owner, viewer),
        bloque = q::est_bloque(owner, viewer),
    )
}

fn non_authentifie(ctx: &Ctx) -> NvResult<Uuid> {
    ctx.actor.uid().map_err(|_| NvError::refused("Non authentifié"))
}

/// `friends_on_map` : la dernière position de chaque ami que je peux voir —
/// partagée (récente), ou donnée en réponse à MA demande (le temps qu'elle
/// vaut).
async fn friends_on_map(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "with vus as (
           select f.user_id, f.lat, f.lon, f.acc, f.at, false as revealed
             from public.friend_locations f
            where f.user_id <> $1::uuid
              and f.at > now() - (select friend_position_max_age from public.map_rules)
              and {voit}
           union all
           select v.target_id, v.lat, v.lon, v.acc, v.at, true
             from public.location_reveals v
            where v.requester_id = $1::uuid and v.expires_at > now()
              and {amis} and not {bloque}
         ),
         dernier as (select distinct on (vus.user_id) vus.* from vus order by vus.user_id, vus.at desc)
         select coalesce(json_agg(t order by t.user_id), '[]'::json) from (
           select d.user_id, d.lat, d.lon, d.acc, d.at, p.display_name, p.avatar_url, d.revealed
             from dernier d join public.profiles p on p.id = d.user_id) t",
        voit = peut_voir_position("f.user_id", "$1::uuid"),
        amis = q::sont_amis("v.target_id", "$1::uuid"),
        bloque = q::est_bloque("v.target_id", "$1::uuid"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

fn zero() -> Option<f64> {
    Some(0.0)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Position {
    p_lat: Option<f64>,
    p_lon: Option<f64>,
    #[serde(default = "zero")]
    p_acc: Option<f64>,
}

/// `share_my_location` : ma position (carte ouverte) — déposée seulement si
/// je partage, et au rythme des règles ; rend vrai si elle l'a été.
async fn share_my_location(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Position = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let (Some(lat), Some(lon)) = (a.p_lat, a.p_lon) else { return Ok(json!(false)) };
    Ok(json!(positions::enregistrer(ctx.db(), moi, lat, lon, a.p_acc, true).await?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Partage {
    p_on: Option<bool>,
}

/// `set_location_sharing` : partager ma position, ou arrêter — arrêter
/// EFFACE ma position.
async fn set_location_sharing(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Partage = parse(args)?;
    sqlx::query!(
        "insert into public.location_sharing (user_id, sharing, updated_at) values ($1, $2, now())
         on conflict (user_id) do update set sharing = excluded.sharing, updated_at = now()",
        moi,
        a.p_on
    )
    .execute(ctx.db())
    .await?;
    if a.p_on == Some(false) {
        sqlx::query!("delete from public.friend_locations where user_id = $1", moi)
            .execute(ctx.db())
            .await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cacher {
    p_friend: Uuid,
    p_hidden: Option<bool>,
}

/// `set_location_hidden` : cacher ma position à un ami (ou la lui montrer
/// de nouveau).
async fn set_location_hidden(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Cacher = parse(args)?;
    if a.p_hidden == Some(true) {
        sqlx::query!(
            "insert into public.location_hidden_from (owner_id, friend_id) values ($1, $2) on conflict do nothing",
            moi,
            a.p_friend
        )
        .execute(ctx.db())
        .await?;
    } else {
        sqlx::query!("delete from public.location_hidden_from where owner_id = $1 and friend_id = $2", moi, a.p_friend)
            .execute(ctx.db())
            .await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Demande {
    p_friend: Uuid,
}

/// `request_location` : demander sa position à un ami — une demande dans
/// notre conversation, qu'il accepte ou non ; pas deux fois de suite.
async fn request_location(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Demande = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    if a.p_friend == moi {
        return Err(NvError::refused("Demande impossible"));
    }
    if !acces::sont_amis(ctx.db(), moi, a.p_friend).await? || acces::is_blocked(ctx.db(), moi, a.p_friend).await? {
        return Err(NvError::refused("Seulement entre amis"));
    }
    let recente = sqlx::query_scalar!(
        r#"select exists (select 1 from public.location_requests
                           where requester_id = $1 and target_id = $2
                             and created_at > now() - (select location_request_gap from public.map_rules)) as "b!""#,
        moi,
        a.p_friend
    )
    .fetch_one(ctx.db())
    .await?;
    if recente {
        return Err(NvError::refused("Demande déjà envoyée : patiente un peu"));
    }
    let conv = conversation_directe(ctx, Some(moi), a.p_friend).await?;
    let (demande, message) = (Uuid::new_v4(), Uuid::new_v4());
    sqlx::query!(
        "insert into public.location_requests (id, requester_id, target_id, message_id) values ($1, $2, $3, $4)",
        demande,
        moi,
        a.p_friend,
        message
    )
    .execute(ctx.db())
    .await?;
    let corps = demande.to_string();
    messages::ecrire(
        ctx.db(),
        Nouveau {
            id: Some(message),
            conversation_id: conv,
            sender_id: moi,
            kind: Some("location_request"),
            body: Some(&corps),
            ..Default::default()
        },
    )
    .await?;
    Ok(json!(demande))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reponse {
    p_request: Uuid,
    p_accept: Option<bool>,
    #[serde(default)]
    p_lat: Option<f64>,
    #[serde(default)]
    p_lon: Option<f64>,
    #[serde(default = "zero")]
    p_acc: Option<f64>,
}

/// `answer_location_request` : répondre à une demande de position — oui
/// (ma position, au seul demandeur, pour `location_reveal_for`) ou non.
async fn answer_location_request(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Reponse = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let d = sqlx::query!(
        r#"select q.requester_id, q.answered_at, q.created_at < now() - r.location_request_ttl as "expiree!"
             from public.location_requests q, public.map_rules r
            where q.id = $1 and q.target_id = $2 for update of q"#,
        a.p_request,
        moi
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Demande introuvable"))?;
    if d.answered_at.is_some() {
        return Err(NvError::refused("Déjà répondu"));
    }
    if d.expiree {
        return Err(NvError::refused("Demande expirée"));
    }
    let accepte = a.p_accept == Some(true);
    let dans_les_bornes = matches!((a.p_lat, a.p_lon), (Some(la), Some(lo)) if (-90.0..=90.0).contains(&la) && (-180.0..=180.0).contains(&lo));
    if accepte && !dans_les_bornes {
        return Err(NvError::refused("Position hors bornes"));
    }
    sqlx::query!(
        "update public.location_requests set answered_at = now(), accepted = $2 where id = $1",
        a.p_request,
        a.p_accept
    )
    .execute(ctx.db())
    .await?;
    if accepte {
        sqlx::query!(
            "insert into public.location_reveals (requester_id, target_id, lat, lon, acc, at, expires_at)
             select $1, $2, $3, $4, greatest(0, coalesce($5::float8, 0)), now(), now() + r.location_reveal_for from public.map_rules r
             on conflict (requester_id, target_id) do update
               set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, at = excluded.at, expires_at = excluded.expires_at",
            d.requester_id,
            moi,
            a.p_lat,
            a.p_lon,
            a.p_acc
        )
        .execute(ctx.db())
        .await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneDemande {
    p_request: Uuid,
}

/// `location_request_state` : où en est une demande (pour ses deux parties).
async fn location_request_state(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: UneDemande = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!" from (
             select case when q.answered_at is null and q.created_at < now() - r.location_request_ttl then 'expiree'
                         when q.answered_at is null then 'en_attente'
                         when q.accepted then 'acceptee'
                         else 'refusee' end as state,
                    q.requester_id, q.target_id, q.created_at, q.created_at + r.location_request_ttl as expires_at
               from public.location_requests q, public.map_rules r
              where q.id = $1 and $2 in (q.requester_id, q.target_id)) t"#,
        a.p_request,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Autour {
    p_lat: Option<f64>,
    p_lng: Option<f64>,
}

/// Les Vibes publiques autour de ce point, dans le rayon de la carte et la
/// fraîcheur du fil.
fn vibes_de_la_carte(moi: &str, lat: &str, lng: &str) -> String {
    autour::vibes_autour(
        moi,
        lat,
        lng,
        "(select vibes_radius_m from public.map_rules)",
        "(now() - (select freshness from public.feed_rules where id))",
    )
}

/// `map_vibes_around` : les Vibes de la carte — les plus aimées
/// (`populaire`) et les plus récentes.
async fn map_vibes_around(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Autour = parse(args)?;
    let sql = format!(
        "with r as (select * from public.map_rules),
         v as (select a.id, a.lat, a.lng, a.created_at,
                      (select count(*)::integer from public.content_likes l where l.content_id = a.id) as likes
                 from ({autour}) a where a.kind = 'card'),
         pop as (select v.id from v where v.likes > 0 order by v.likes desc, v.created_at desc limit (select vibes_popular_count from r)),
         rec as (select v.id from v order by v.created_at desc limit (select vibes_recent_count from r))
         select coalesce(json_agg(t), '[]'::json) from (
           select v.id, v.lat, v.lng, v.likes, v.id in (select pop.id from pop) as populaire, v.created_at
             from v where v.id in (select pop.id from pop union select rec.id from rec)) t",
        autour = vibes_de_la_carte("$1::uuid", "$2::float8", "$3::float8")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(a.p_lat).bind(a.p_lng).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Vibes {
    p_ids: Vec<Uuid>,
    p_lat: Option<f64>,
    p_lng: Option<f64>,
}

/// `map_vibe_items` : ces Vibes de la carte, à lire (seulement si elles sont
/// bien autour du point), la plus récente d'abord.
async fn map_vibe_items(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Vibes = parse(args)?;
    let sql = format!(
        "select coalesce(jsonb_agg({complete} order by li.created_at desc), '[]'::jsonb)
           from public.library_items li join ({autour}) a on a.id = li.id
          where li.id = any($4::uuid[]) and li.kind = 'card'",
        complete = publication_complete("li"),
        autour = vibes_de_la_carte("$1::uuid", "$2::float8", "$3::float8")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql)
        .bind(moi)
        .bind(a.p_lat)
        .bind(a.p_lng)
        .bind(&a.p_ids)
        .fetch_one(ctx.db())
        .await?)
}

// ─── Ce que l'app lisait directement ───────────────────────────────────────

/// `location_sharing_mine` : est-ce que je partage ma position ?
async fn location_sharing_mine(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select json_build_object('sharing', sharing) as "j!" from public.location_sharing where user_id = $1"#,
        moi
    )
    .fetch_optional(ctx.db())
    .await?
    .unwrap_or(Value::Null))
}

/// `location_hidden_list` : les amis à qui je cache ma position.
async fn location_hidden_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('friend_id', friend_id)), '[]'::json) as "j!"
             from public.location_hidden_from where owner_id = $1"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

/// `map_rules_walking` : « Rejoindre » (l'itinéraire à pied) est-il ouvert ?
async fn map_rules_walking(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select json_build_object('walking_route_enabled', walking_route_enabled) as "j!" from public.map_rules limit 1"#
    )
    .fetch_one(ctx.db())
    .await?)
}
