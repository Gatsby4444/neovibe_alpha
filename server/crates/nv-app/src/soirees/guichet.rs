//! Les guichets des soirées (docs/serveur-rust.md, annexe A.7).
//!
//! Deux origines, deux filtres qui ne se mélangent jamais (CLAUDE.md) : une
//! soirée **privée** filtre par la relation (être du groupe, invité par un
//! ami), une soirée **ouverte** ou **d'établissement** par le lieu (être sur
//! place).
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use super::cuisine;
use super::regles::{self, amis_presents, present};
use crate::acces::{self, q, vrai, P};
use crate::carte::autour::distance_m;
use crate::conversations::messages::{self, Nouveau};
use crate::fichiers::regles::{premier_dossier, soiree_de_l_affiche};
use crate::vibes::enumeration;

ops![
    create_open_event => create_open_event,
    create_private_event => create_private_event,
    close_event => close_event,
    join_event => join_event,
    leave_event => leave_event,
    report_event_position => report_event_position,
    invite_to_event => invite_to_event,
    remove_from_event => remove_from_event,
    set_event_member_role => set_event_member_role,
    update_event_settings => update_event_settings,
    set_event_details => set_event_details,
    set_event_place => set_event_place,
    set_event_size => set_event_size,
    post_challenge => post_challenge,
    event_hot_spots => event_hot_spots,
    event_people => event_people,
    event_recap => event_recap,
    my_events => my_events,
    nearby_events => nearby_events,
    my_meetings => my_meetings,
    met_before => met_before,
    event_rules_map => event_rules_map,
    event_presence_mine => event_presence_mine,
    event_challenges_list => event_challenges_list,
    meeting_delete => meeting_delete,
];

fn non_authentifie(ctx: &Ctx) -> NvResult<Uuid> {
    ctx.actor.uid().map_err(|_| NvError::refused("Non authentifié"))
}

/// Un titre de soirée : rogné de ses espaces (comme `btrim`), vide = aucun.
fn titre(brut: Option<&str>) -> Option<&str> {
    brut.map(|t| t.trim_matches(' ')).filter(|t| !t.is_empty())
}

/// Sortir de toute autre soirée (une seule à la fois) — `sauf` : celle où
/// l'on entre.
async fn sortir_des_autres(ctx: &mut Ctx, moi: Uuid, sauf: Option<Uuid>) -> NvResult<()> {
    sqlx::query!(
        "update public.event_presences set left_at = now(), left_reason = 'manual'
          where user_id = $1 and left_at is null and ($2::uuid is null or event_id <> $2)",
        moi,
        sauf
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("delete from public.event_positions where user_id = $1 and ($2::uuid is null or event_id <> $2)", moi, sauf)
        .execute(ctx.db())
        .await?;
    Ok(())
}

// ─── Créer ─────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ouverte {
    p_title: Option<String>,
    p_lat: Option<f64>,
    p_lon: Option<f64>,
    p_ends_at: Option<DateTime<Utc>>,
    #[serde(default)]
    p_radius_m: Option<i32>,
    #[serde(default)]
    p_acc: Option<f64>,
}

/// `create_open_event` : une soirée ouverte, là où je suis, jusqu'à une
/// heure de fin (24 h au plus). J'en suis l'organisateur, et présent.
async fn create_open_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Ouverte = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    regles::lieu_precis(ctx.db(), a.p_lat, a.p_acc).await?;
    let Some(nom) = titre(a.p_title.as_deref()) else { return Err(NvError::refused("Un événement a un nom")) };
    let (Some(lat), Some(lon)) = (a.p_lat, a.p_lon) else {
        return Err(NvError::refused("Un événement ouvert a un lieu : là où tu es"));
    };
    let fin = match a.p_ends_at {
        Some(f) if f > ctx.now => f,
        _ => return Err(NvError::refused("Un événement ouvert a une heure de fin")),
    };
    if fin > ctx.now + chrono::Duration::hours(24) {
        return Err(NvError::refused("Un événement ouvert dure au plus 24 h"));
    }
    let conv = sqlx::query_scalar!(
        "insert into public.conversations (conversation_type, title, created_by) values ('event', $1, $2) returning id",
        nom,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    let rayon = regles::rayon_de_taille(ctx.db(), a.p_radius_m).await?;
    let soiree = sqlx::query_scalar!(
        "insert into public.events (kind, title, created_by, conversation_id, lat, lon, radius_m, starts_at, scheduled_end_at, opened_at)
         values ('open', $1, $2, $3, $4, $5, $6, now(), $7, now()) returning id",
        nom,
        moi,
        conv,
        lat,
        lon,
        rayon,
        fin
    )
    .fetch_one(ctx.db())
    .await?;
    sqlx::query!(
        "insert into public.event_group_members (event_id, user_id, role, added_by) values ($1, $2, 'admin', $2)",
        soiree,
        moi
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("insert into public.conversation_members (conversation_id, user_id) values ($1, $2)", conv, moi)
        .execute(ctx.db())
        .await?;
    sortir_des_autres(ctx, moi, None).await?;
    sqlx::query!(
        "insert into public.event_presences (event_id, user_id, last_position_at) values ($1, $2, now())",
        soiree,
        moi
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!(
        "insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at) values ($1, $2, $3, $4, null, now())
         on conflict (event_id, user_id) do update set lat = excluded.lat, lon = excluded.lon, reported_at = now()",
        soiree,
        moi,
        lat,
        lon
    )
    .execute(ctx.db())
    .await?;
    Ok(json!(soiree))
}

fn aucun() -> Option<Vec<Uuid>> {
    Some(Vec::new())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Privee {
    p_title: Option<String>,
    #[serde(default)]
    p_starts_at: Option<DateTime<Utc>>,
    #[serde(default)]
    p_ends_at: Option<DateTime<Utc>>,
    #[serde(default)]
    p_lat: Option<f64>,
    #[serde(default)]
    p_lon: Option<f64>,
    #[serde(default = "aucun")]
    p_member_ids: Option<Vec<Uuid>>,
    #[serde(default)]
    p_acc: Option<f64>,
}

/// `create_private_event` : une soirée privée (un groupe éphémère), avec ou
/// sans lieu fixe. On n'y invite que ses amis.
async fn create_private_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Privee = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    regles::lieu_precis(ctx.db(), a.p_lat, a.p_acc).await?;
    let Some(nom) = titre(a.p_title.as_deref()) else { return Err(NvError::refused("Un événement a un nom")) };
    let conv = sqlx::query_scalar!(
        "insert into public.conversations (conversation_type, title, created_by) values ('event', $1, $2) returning id",
        nom,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    let soiree = sqlx::query_scalar!(
        "insert into public.events (kind, title, created_by, conversation_id, lat, lon, radius_m, starts_at, scheduled_end_at)
         values ('private', $1, $2, $3, $4, $5,
                 case when $4::float8 is null then null else (select size_bar_m from public.event_rules) end,
                 coalesce($6, now()), $7)
         returning id",
        nom,
        moi,
        conv,
        a.p_lat,
        a.p_lon,
        a.p_starts_at,
        a.p_ends_at
    )
    .fetch_one(ctx.db())
    .await?;
    sqlx::query!(
        "insert into public.event_group_members (event_id, user_id, role, added_by) values ($1, $2, 'admin', $2)",
        soiree,
        moi
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("insert into public.conversation_members (conversation_id, user_id) values ($1, $2)", conv, moi)
        .execute(ctx.db())
        .await?;
    for m in a.p_member_ids.unwrap_or_default() {
        if m != moi && acces::sont_amis(ctx.db(), moi, m).await? && !acces::is_blocked(ctx.db(), moi, m).await? {
            sqlx::query!(
                "insert into public.event_group_members (event_id, user_id, role, added_by) values ($1, $2, 'admin', $3) on conflict do nothing",
                soiree,
                m,
                moi
            )
            .execute(ctx.db())
            .await?;
            sqlx::query!(
                "insert into public.conversation_members (conversation_id, user_id) values ($1, $2) on conflict do nothing",
                conv,
                m
            )
            .execute(ctx.db())
            .await?;
        }
    }
    Ok(json!(soiree))
}

// ─── Entrer, sortir, être là ───────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneSoiree {
    p_event: Uuid,
}

/// `close_event` : l'organisateur ferme sa soirée.
async fn close_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: UneSoiree = parse(args)?;
    let existe = sqlx::query_scalar!(r#"select exists (select 1 from public.events where id = $1) as "b!""#, a.p_event)
        .fetch_one(ctx.db())
        .await?;
    if !existe {
        return Err(NvError::refused("Événement introuvable"));
    }
    if !vrai(ctx.db(), &q::gere_evenement("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Seul l'organisateur ferme l'événement"));
    }
    cuisine::fermer(ctx.db(), a.p_event, "host").await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entree {
    p_event: Uuid,
    p_lat: Option<f64>,
    p_lon: Option<f64>,
    #[serde(default)]
    p_acc: Option<f64>,
}

/// `join_event` : entrer dans une soirée — EN Y ÉTANT. Une soirée privée
/// demande en plus d'être du groupe.
async fn join_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Entree = parse(args)?;
    let e = sqlx::query!(
        r#"select kind::text as "kind!", closed_at, starts_at, lat, conversation_id from public.events where id = $1 for update"#,
        a.p_event
    )
    .fetch_optional(ctx.db())
    .await?;
    let Some(e) = e.filter(|e| e.closed_at.is_none()) else { return Err(NvError::refused("Événement fermé")) };
    if e.starts_at > ctx.now {
        return Err(NvError::refused("L'événement n'a pas commencé"));
    }
    if e.kind == "private" && !vrai(ctx.db(), &q::membre_evenement("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Tu n'es pas invité"));
    }
    let (Some(lat), Some(lon)) = (a.p_lat, a.p_lon) else { return Err(NvError::refused("Position requise")) };
    if e.lat.is_some() {
        let sql = format!(
            "select {d}, {d} > coalesce(e.radius_m, r.size_bar_m) + coalesce(least($4::float8, r.entry_margin_max_m), 0)
               from public.events e, public.event_rules r where e.id = $1::uuid",
            d = distance_m("$2::float8", "$3::float8", "e.lat", "e.lon")
        );
        let (d, trop_loin): (f64, bool) =
            sqlx::query_as(&sql).bind(a.p_event).bind(lat).bind(lon).bind(a.p_acc).fetch_one(ctx.db()).await?;
        if trop_loin {
            return Err(NvError::refused(format!("Trop loin : {} m", d.round_ties_even())));
        }
    } else if regles::loin_de_la_soiree(ctx.db(), a.p_event, moi, lat, lon, a.p_acc).await? {
        return Err(NvError::refused("Trop loin des participants"));
    }
    sortir_des_autres(ctx, moi, Some(a.p_event)).await?;
    let deja = sqlx::query_scalar!(
        "select id from public.event_presences where event_id = $1 and user_id = $2 and left_at is null",
        a.p_event,
        moi
    )
    .fetch_optional(ctx.db())
    .await?;
    let presence = match deja {
        Some(id) => {
            sqlx::query!("update public.event_presences set last_position_at = now() where id = $1", id)
                .execute(ctx.db())
                .await?;
            id
        }
        None => {
            sqlx::query_scalar!(
                "insert into public.event_presences (event_id, user_id, last_position_at) values ($1, $2, now()) returning id",
                a.p_event,
                moi
            )
            .fetch_one(ctx.db())
            .await?
        }
    };
    sqlx::query!(
        "insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at) values ($1, $2, $3, $4, $5, now())
         on conflict (event_id, user_id) do update set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, reported_at = now()",
        a.p_event,
        moi,
        lat,
        lon,
        a.p_acc
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("update public.events set opened_at = coalesce(opened_at, now()) where id = $1", a.p_event)
        .execute(ctx.db())
        .await?;
    sqlx::query!(
        "insert into public.conversation_members (conversation_id, user_id) values ($1, $2) on conflict do nothing",
        e.conversation_id,
        moi
    )
    .execute(ctx.db())
    .await?;
    Ok(json!(presence))
}

/// `leave_event` : je sors de la soirée.
async fn leave_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: UneSoiree = parse(args)?;
    sqlx::query!(
        "update public.event_presences set left_at = now(), left_reason = 'manual' where event_id = $1 and user_id = $2 and left_at is null",
        a.p_event,
        moi
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("delete from public.event_positions where event_id = $1 and user_id = $2", a.p_event, moi)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Position {
    p_lat: Option<f64>,
    p_lon: Option<f64>,
    #[serde(default)]
    p_acc: Option<f64>,
}

/// `report_event_position` (le service natif de présence) : ma position
/// pendant une soirée — `none` (je ne suis dans aucune), `present`, ou `away`
/// (trop loin : je sors).
async fn report_event_position(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Position = parse(args)?;
    let p = sqlx::query!("select id, event_id from public.event_presences where user_id = $1 and left_at is null", moi)
        .fetch_optional(ctx.db())
        .await?;
    let Some(p) = p else { return Ok(json!("none")) };
    let (Some(lat), Some(lon)) = (a.p_lat, a.p_lon) else { return Ok(json!("present")) };
    if regles::loin_de_la_soiree(ctx.db(), p.event_id, moi, lat, lon, a.p_acc).await? {
        sqlx::query!("update public.event_presences set left_at = now(), left_reason = 'away' where id = $1", p.id)
            .execute(ctx.db())
            .await?;
        sqlx::query!("delete from public.event_positions where event_id = $1 and user_id = $2", p.event_id, moi)
            .execute(ctx.db())
            .await?;
        return Ok(json!("away"));
    }
    sqlx::query!(
        "insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at) values ($1, $2, $3, $4, $5, now())
         on conflict (event_id, user_id) do update set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, reported_at = now()",
        p.event_id,
        moi,
        lat,
        lon,
        a.p_acc
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("update public.event_presences set last_position_at = now() where id = $1", p.id)
        .execute(ctx.db())
        .await?;
    Ok(json!("present"))
}

// ─── Le groupe d'une soirée privée ─────────────────────────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Quelquun {
    p_event: Uuid,
    p_user: Uuid,
}

/// `invite_to_event` : inviter un AMI (au sens strict) dans une soirée
/// privée — il en devient admin, comme sur WhatsApp.
async fn invite_to_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Quelquun = parse(args)?;
    if !vrai(ctx.db(), &regles::peut_inviter("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Tu ne peux pas inviter ici"));
    }
    if !acces::sont_amis(ctx.db(), moi, a.p_user).await? || acces::is_blocked(ctx.db(), moi, a.p_user).await? {
        return Err(NvError::refused("On n'invite que ses amis"));
    }
    let conv = sqlx::query_scalar!("select conversation_id from public.events where id = $1", a.p_event)
        .fetch_optional(ctx.db())
        .await?;
    sqlx::query!(
        "insert into public.event_group_members (event_id, user_id, role, added_by) values ($1, $2, 'admin', $3) on conflict do nothing",
        a.p_event,
        a.p_user,
        moi
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!(
        "insert into public.conversation_members (conversation_id, user_id) values ($1, $2) on conflict do nothing",
        conv,
        a.p_user
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `remove_from_event` : retirer quelqu'un d'une soirée privée (ou en
/// partir soi-même) — jamais son créateur.
async fn remove_from_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Quelquun = parse(args)?;
    let e = sqlx::query!(r#"select kind::text as "kind!", created_by, conversation_id from public.events where id = $1"#, a.p_event)
        .fetch_optional(ctx.db())
        .await?;
    let Some(e) = e.filter(|e| e.kind == "private") else { return Err(NvError::refused("Événement introuvable")) };
    if a.p_user == e.created_by {
        return Err(NvError::refused("Le créateur ne se retire pas"));
    }
    if a.p_user != moi && !vrai(ctx.db(), &regles::peut_retirer("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Tu ne peux pas retirer quelqu'un ici"));
    }
    let raison = if a.p_user == moi { "manual" } else { "removed" };
    sqlx::query!(
        "update public.event_presences set left_at = now(), left_reason = $3::text::public.event_leave_reason
          where event_id = $1 and user_id = $2 and left_at is null",
        a.p_event,
        a.p_user,
        raison
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("delete from public.event_positions where event_id = $1 and user_id = $2", a.p_event, a.p_user)
        .execute(ctx.db())
        .await?;
    sqlx::query!("delete from public.event_group_members where event_id = $1 and user_id = $2", a.p_event, a.p_user)
        .execute(ctx.db())
        .await?;
    sqlx::query!(
        "delete from public.conversation_members where conversation_id = $1 and user_id = $2",
        e.conversation_id,
        a.p_user
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Role {
    p_event: Uuid,
    p_user: Uuid,
    p_role: Option<String>,
}

/// `set_event_member_role` : le créateur règle les rôles (lui reste admin).
async fn set_event_member_role(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Role = parse(args)?;
    let role = enumeration(ctx.db(), "event_role", a.p_role.as_deref()).await?;
    let createur = sqlx::query_scalar!(
        r#"select exists (select 1 from public.events where id = $1 and created_by = $2 and closed_at is null) as "b!""#,
        a.p_event,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if !createur {
        return Err(NvError::refused("Seul le créateur règle les rôles"));
    }
    if a.p_user == moi {
        return Err(NvError::refused("Le créateur reste admin"));
    }
    sqlx::query!(
        "update public.event_group_members set role = $3::text::public.event_role where event_id = $1 and user_id = $2",
        a.p_event,
        a.p_user,
        role
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

// ─── Régler la soirée ──────────────────────────────────────────────────────

fn faux() -> Option<bool> {
    Some(false)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reglages {
    p_event: Uuid,
    #[serde(default)]
    p_title: Option<String>,
    #[serde(default)]
    p_members_can_add: Option<bool>,
    #[serde(default)]
    p_members_can_remove: Option<bool>,
    #[serde(default)]
    p_ends_at: Option<DateTime<Utc>>,
    #[serde(default)]
    p_lat: Option<f64>,
    #[serde(default)]
    p_lon: Option<f64>,
    #[serde(default = "faux")]
    p_clear_place: Option<bool>,
}

/// `update_event_settings` : l'organisateur règle sa soirée (nom, droits
/// des membres, heure de fin, lieu).
async fn update_event_settings(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Reglages = parse(args)?;
    let e = sqlx::query!("select closed_at, conversation_id from public.events where id = $1 for update", a.p_event)
        .fetch_optional(ctx.db())
        .await?;
    let Some(e) = e.filter(|e| e.closed_at.is_none()) else { return Err(NvError::refused("Événement introuvable")) };
    if !vrai(ctx.db(), &q::gere_evenement("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Seul l'organisateur règle l'événement"));
    }
    let effacer = a.p_clear_place.unwrap_or(false);
    sqlx::query!(
        "update public.events
            set title = coalesce(nullif(btrim($2), ''), title),
                members_can_add = coalesce($3, members_can_add),
                members_can_remove = coalesce($4, members_can_remove),
                scheduled_end_at = coalesce($5, scheduled_end_at),
                lat = case when $8 then null else coalesce($6, lat) end,
                lon = case when $8 then null else coalesce($7, lon) end,
                radius_m = case when $8 then null
                                when $6::float8 is not null then coalesce(radius_m, (select size_bar_m from public.event_rules))
                                else radius_m end
          where id = $1",
        a.p_event,
        a.p_title,
        a.p_members_can_add,
        a.p_members_can_remove,
        a.p_ends_at,
        a.p_lat,
        a.p_lon,
        effacer
    )
    .execute(ctx.db())
    .await?;
    if let Some(t) = &a.p_title {
        sqlx::query!("update public.conversations set title = btrim($2) where id = $1", e.conversation_id, t)
            .execute(ctx.db())
            .await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Details {
    p_event: Uuid,
    p_description: Option<String>,
    p_poster_path: Option<String>,
    #[serde(default = "faux")]
    p_clear_poster: Option<bool>,
}

/// `set_event_details` : la description et l'affiche — par l'organisateur,
/// pendant la soirée. L'affiche doit être celle qu'IL vient de déposer POUR
/// cette soirée ; l'ancienne sera effacée.
async fn set_event_details(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Details = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    if !vrai(ctx.db(), &q::gere_evenement_ouvert("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Seul l'organisateur modifie la soirée, et pendant qu'elle a lieu"));
    }
    let description = a.p_description.as_deref().map(|d| d.trim_matches(' ')).filter(|d| !d.is_empty());
    if description.is_some_and(|d| d.chars().count() > 200) {
        return Err(NvError::refused("Description trop longue (200 caractères au plus)"));
    }
    let ancienne = sqlx::query_scalar!("select poster_path from public.events where id = $1", a.p_event)
        .fetch_optional(ctx.db())
        .await?
        .flatten();
    if let Some(affiche) = &a.p_poster_path {
        let a_moi = premier_dossier(affiche) == Some(moi.to_string().as_str());
        let pour_elle = soiree_de_l_affiche(affiche) == Some(a.p_event);
        if !a_moi || !pour_elle || ctx.entrepot()?.taille("event_posters", affiche).await?.is_none() {
            return Err(NvError::refused("Affiche introuvable"));
        }
    }
    let effacer = a.p_clear_poster.unwrap_or(false);
    sqlx::query!(
        "update public.events set description = $2,
                poster_path = case when $4 then null else coalesce($3, poster_path) end
          where id = $1",
        a.p_event,
        description,
        a.p_poster_path,
        effacer
    )
    .execute(ctx.db())
    .await?;
    if let Some(vieille) = ancienne {
        if effacer || a.p_poster_path.as_deref().is_some_and(|p| p != vieille) {
            cuisine::oublier_l_affiche(ctx.db(), &vieille).await?;
        }
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Lieu {
    p_event: Uuid,
    p_place_name: Option<String>,
}

/// `set_event_place` : le créateur nomme le lieu (60 caractères au plus).
async fn set_event_place(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Lieu = parse(args)?;
    let nom = a.p_place_name.as_deref().map(|n| n.trim_matches(' ')).filter(|n| !n.is_empty());
    if nom.is_some_and(|n| n.chars().count() > 60) {
        return Err(NvError::refused("Nom du lieu trop long (60 caractères au plus)"));
    }
    let n = sqlx::query!(
        "update public.events set place_name = $3 where id = $1 and created_by = $2 and closed_at is null",
        a.p_event,
        moi,
        nom
    )
    .execute(ctx.db())
    .await?
    .rows_affected();
    if n == 0 {
        return Err(NvError::refused("Seul le créateur nomme le lieu, et pendant l'événement"));
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Taille {
    p_event: Uuid,
    p_size: Option<String>,
}

/// `set_event_size` : la taille d'une soirée à lieu fixe — bar, grand lieu,
/// plein air.
async fn set_event_size(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Taille = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    if !vrai(ctx.db(), &q::gere_evenement_ouvert("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Seul l'organisateur règle la soirée, et pendant qu'elle a lieu"));
    }
    let rayon = sqlx::query_scalar!(
        "select case $1::text when 'bar' then size_bar_m when 'grand' then size_grand_m when 'plein_air' then size_plein_air_m end
           from public.event_rules limit 1",
        a.p_size
    )
    .fetch_one(ctx.db())
    .await?;
    let Some(rayon) = rayon else {
        return Err(NvError::refused(format!("Taille inconnue : {}", a.p_size.as_deref().unwrap_or("<NULL>"))));
    };
    let n = sqlx::query!("update public.events set radius_m = $2 where id = $1 and lat is not null", a.p_event, rayon)
        .execute(ctx.db())
        .await?
        .rows_affected();
    if n == 0 {
        return Err(NvError::refused("Une soirée sans lieu fixe n'a pas de taille"));
    }
    Ok(json!(rayon))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Defi {
    p_event: Uuid,
    p_text: Option<String>,
}

/// `post_challenge` : poser un défi — il faut être sur place. Il s'annonce
/// dans le chat de la soirée.
async fn post_challenge(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Defi = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let e = sqlx::query!("select closed_at, conversation_id from public.events where id = $1", a.p_event)
        .fetch_optional(ctx.db())
        .await?;
    let Some(e) = e.filter(|e| e.closed_at.is_none()) else { return Err(NvError::refused("Événement fermé")) };
    if !vrai(ctx.db(), &present("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await? {
        return Err(NvError::refused("Il faut être sur place"));
    }
    let texte = a.p_text.as_deref().map(|t| t.trim_matches(' '));
    let defi = sqlx::query_scalar!(
        "insert into public.event_challenges (event_id, author_id, text) values ($1, $2, $3) returning id",
        a.p_event,
        moi,
        texte
    )
    .fetch_one(ctx.db())
    .await?;
    let annonce = texte.map(|t| format!("🎯 Défi : {t}"));
    messages::ecrire(
        ctx.db(),
        Nouveau {
            conversation_id: e.conversation_id,
            sender_id: moi,
            kind: Some("text"),
            body: annonce.as_deref(),
            ..Default::default()
        },
    )
    .await?;
    Ok(json!(defi))
}

// ─── Lire ──────────────────────────────────────────────────────────────────

/// La soirée me concerne-t-elle (membre, présent, gérant du lieu) ?
async fn concerne(ctx: &mut Ctx, soiree: Uuid, moi: Uuid) -> NvResult<bool> {
    vrai(ctx.db(), &q::concerne_evenement("$1::uuid", "$2::uuid"), &[P::U(soiree), P::U(moi)]).await
}

/// `event_hot_spots` : les points chauds d'une soirée (où sont les présents,
/// par cases de `hot_spot_cell_m`), plus son lieu — une vue dérivée des
/// positions, jamais un fait stocké.
async fn event_hot_spots(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: UneSoiree = parse(args)?;
    if !concerne(ctx, a.p_event, moi).await? {
        return Err(NvError::refused("Événement introuvable"));
    }
    Ok(sqlx::query_scalar!(
        r#"with c as (select (hot_spot_cell_m / 111000.0)::float8 as deg, away_after from public.event_rules),
                e as (select lat, lon from public.events where id = $1)
           select coalesce(json_agg(t), '[]'::json) as "j!" from (
             select (floor(p.lat / c.deg) * c.deg + c.deg / 2)::float8 as lat,
                    (floor(p.lon / c.deg) * c.deg + c.deg / 2)::float8 as lon,
                    count(*)::integer as headcount
               from public.event_positions p
               join public.event_presences pr on pr.event_id = p.event_id and pr.user_id = p.user_id and pr.left_at is null
               cross join c
              where p.event_id = $1 and p.reported_at > now() - c.away_after and exists (select 1 from e)
              group by 1, 2
             union all
             select e.lat, e.lon, 0 from e where e.lat is not null) t"#,
        a.p_event
    )
    .fetch_one(ctx.db())
    .await?)
}

/// `event_people` : les gens d'une soirée — invités et présents, avec ce
/// qu'ils sont pour moi (`me`, `friend`, `event`…) ; les présents d'abord.
async fn event_people(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: UneSoiree = parse(args)?;
    if !concerne(ctx, a.p_event, moi).await? {
        return Err(NvError::refused("Événement introuvable"));
    }
    let sql = format!(
        "with gens as (
           select m.user_id, m.role, true as invited, m.joined_at from public.event_group_members m where m.event_id = $1::uuid
           union
           select p.user_id, null::public.event_role, false, p.joined_at from public.event_presences p
            where p.event_id = $1::uuid and p.left_at is null
              and not exists (select 1 from public.event_group_members m where m.event_id = $1::uuid and m.user_id = p.user_id)
         )
         select coalesce(json_agg(t order by t.present desc, t.display_name), '[]'::json) from (
           select g.user_id, pr.display_name, pr.pseudo_shown as tag_name, pr.avatar_url, g.role, g.invited,
                  {present} as present,
                  case when g.user_id = $2::uuid then 'me' else {relation} end as relation,
                  g.joined_at
             from gens g join public.profiles pr on pr.id = g.user_id
            where not {bloque}) t",
        present = present("$1::uuid", "g.user_id"),
        relation = q::relation("$2::uuid", "g.user_id"),
        bloque = q::est_bloque("$2::uuid", "g.user_id"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.p_event).bind(moi).fetch_one(ctx.db()).await?)
}

/// `event_recap` : le récap d'une soirée (en cours ou finie) — présents,
/// Vibes du Drop, mes rencontres, mes nouveaux amis, mes amis venus.
async fn event_recap(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: UneSoiree = parse(args)?;
    let existe = sqlx::query_scalar!(r#"select exists (select 1 from public.events where id = $1) as "b!""#, a.p_event)
        .fetch_one(ctx.db())
        .await?;
    if !existe || !concerne(ctx, a.p_event, moi).await? {
        return Err(NvError::refused("Événement introuvable"));
    }
    let sql = format!(
        "select json_agg(t) from (select
           (select count(distinct p.user_id)::integer from public.event_presences p where p.event_id = $1::uuid) as present_count,
           (select count(*)::integer from public.library_vibes v where v.conversation_id = e.conversation_id) as vibe_count,
           (select count(*)::integer from public.meetings m where m.user_id = $2::uuid and m.event_id = $1::uuid) as met_count,
           (select count(*)::integer from public.connections c
             where c.status = 'full' and c.established_at >= e.starts_at
               and ((c.user_low = $2::uuid and exists (select 1 from public.event_presences p where p.event_id = $1::uuid and p.user_id = c.user_high))
                 or (c.user_high = $2::uuid and exists (select 1 from public.event_presences p where p.event_id = $1::uuid and p.user_id = c.user_low))))
             as new_friend_count,
           (select coalesce(array_agg(distinct p.user_id), '{{}}'::uuid[]) from public.event_presences p
             where p.event_id = $1::uuid and p.user_id <> $2::uuid and {amis}) as friends_present
         from public.events e where e.id = $1::uuid) t",
        amis = q::sont_amis("$2::uuid", "p.user_id")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.p_event).bind(moi).fetch_one(ctx.db()).await?)
}

/// `my_events` : les soirées qui me concernent — les ouvertes d'abord, les
/// plus récentes ensuite.
async fn my_events(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "select coalesce(json_agg(t order by (t.closed_at is null) desc, t.starts_at desc), '[]'::json) from (
           select e.id, e.kind, e.title, coalesce(e.place_name, v.name) as venue_name, e.created_by, e.conversation_id,
                  e.lat, e.lon, e.radius_m, e.starts_at, e.scheduled_end_at, e.opened_at, e.closed_at,
                  e.members_can_add, e.members_can_remove, e.library_reveal_at,
                  (select count(*)::integer from public.event_presences p where p.event_id = e.id and p.left_at is null) as present_count,
                  (select count(*)::integer from public.event_group_members m where m.event_id = e.id) as guest_count,
                  {present} as i_am_present,
                  (select m.role from public.event_group_members m where m.event_id = e.id and m.user_id = $1::uuid) as my_role,
                  (e.venue_id is not null and {gere_lieu}) as i_manage,
                  e.description, e.poster_path, {amis} as friends_present
             from public.events e left join public.venues v on v.id = e.venue_id
            where {concerne}) t",
        present = present("e.id", "$1::uuid"),
        gere_lieu = q::gere_lieu("e.venue_id", "$1::uuid"),
        amis = amis_presents("e.id", "$1::uuid"),
        concerne = q::concerne_evenement("e.id", "$1::uuid"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

fn zero() -> Option<i32> {
    Some(0)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Autour {
    p_lat: Option<f64>,
    p_lon: Option<f64>,
    #[serde(default)]
    p_radius_m: Option<i32>,
    #[serde(default = "zero")]
    p_min_present: Option<i32>,
}

/// `nearby_events` : les soirées ouvertes et d'établissement autour de moi,
/// la plus proche d'abord. Le rayon demandé est BORNÉ par la règle (jamais
/// sous le rayon par défaut, jamais au-delà du maximum — plus loin pour les
/// grosses soirées).
async fn nearby_events(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Autour = parse(args)?;
    let sql = format!(
        "with r as (select * from public.event_rules),
         b as (select greatest(coalesce($4::integer, 0), 0) as min_presents from r),
         rayon as (select least(greatest(coalesce($3::integer, r.nearby_radius_m), r.nearby_radius_m),
                                case when b.min_presents >= r.big_event_min_present then r.big_event_radius_m else r.nearby_radius_max_m end) as m
                     from r, b)
         select coalesce(json_agg(t order by t.distance_m), '[]'::json) from (
           select e.id, e.kind, e.title, coalesce(e.place_name, v.name) as venue_name, v.address as venue_address,
                  e.lat, e.lon, e.radius_m, e.starts_at, e.scheduled_end_at,
                  (select count(*)::integer from public.event_presences p where p.event_id = e.id and p.left_at is null) as present_count,
                  round({dist})::integer as distance_m,
                  e.description, e.poster_path, {amis} as friends_present
             from public.events e left join public.venues v on v.id = e.venue_id
            where e.kind in ('venue', 'open') and e.closed_at is null and e.starts_at <= now() and e.lat is not null
              and {dist} <= (select m from rayon)
              and not {bloque}) t
          where t.present_count >= (select min_presents from b)",
        dist = distance_m("$1::float8", "$2::float8", "e.lat", "e.lon"),
        amis = amis_presents("e.id", "$5::uuid"),
        bloque = q::est_bloque("$5::uuid", "e.created_by"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql)
        .bind(a.p_lat)
        .bind(a.p_lon)
        .bind(a.p_radius_m)
        .bind(a.p_min_present)
        .bind(moi)
        .fetch_one(ctx.db())
        .await?)
}

/// `my_meetings` : qui j'ai rencontré, où, quand — la plus récente d'abord.
async fn my_meetings(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "select coalesce(json_agg(t order by t.last_at desc), '[]'::json) from (
           select m.id, m.other_id as user_id, p.display_name, p.pseudo_shown as tag_name, p.avatar_url,
                  m.origin, m.event_id, m.event_title, m.lat, m.lon, m.met_at, m.last_at,
                  {amis} as connected,
                  (select count(*)::integer from public.meetings x where x.user_id = $1::uuid and x.other_id = m.other_id) as times
             from public.meetings m join public.profiles p on p.id = m.other_id
            where m.user_id = $1::uuid and not {bloque}) t",
        amis = q::sont_amis("$1::uuid", "m.other_id"),
        bloque = q::est_bloque("$1::uuid", "m.other_id"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Gens {
    p_users: Vec<Uuid>,
}

/// `met_before` : « vous vous êtes déjà rencontrés » — la dernière rencontre
/// gardée avec chacune de ces personnes, et combien de fois.
async fn met_before(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = non_authentifie(ctx)?;
    let a: Gens = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!" from (
             select d.other_id as user_id, d.origin, d.event_title, d.met_at,
                    (select count(*)::integer from public.meetings x where x.user_id = $1 and x.other_id = d.other_id) as times
               from (select distinct on (m.other_id) m.other_id, m.origin, m.event_title, m.met_at
                       from public.meetings m where m.user_id = $1 and m.other_id = any($2)
                      order by m.other_id, m.last_at desc) d) t"#,
        moi,
        &a.p_users
    )
    .fetch_one(ctx.db())
    .await?)
}

// ─── Ce que l'app lisait directement ───────────────────────────────────────

/// `event_rules_map` : les règles que l'écran de la carte ANNONCE (rayon,
/// seuil des grosses soirées).
async fn event_rules_map(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select json_build_object('nearby_radius_m', nearby_radius_m, 'nearby_radius_max_m', nearby_radius_max_m,
                                    'big_event_min_present', big_event_min_present) as "j!"
             from public.event_rules limit 1"#
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ParSoiree {
    event_id: Uuid,
}

/// `event_presence_mine` : y ai-je été (une présence, même finie) ?
async fn event_presence_mine(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: ParSoiree = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('id', t.id)), '[]'::json) as "j!"
             from (select id from public.event_presences where event_id = $1 and user_id = $2 limit 1) t"#,
        a.event_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

/// `event_challenges_list` : les défis d'une soirée qui me concerne, le plus
/// récent d'abord.
async fn event_challenges_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: ParSoiree = parse(args)?;
    if !concerne(ctx, a.event_id, moi).await? {
        return Ok(json!([]));
    }
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('id', c.id, 'event_id', c.event_id, 'author_id', c.author_id,
                                                        'text', c.text, 'created_at', c.created_at)
                                    order by c.created_at desc), '[]'::json) as "j!"
             from public.event_challenges c where c.event_id = $1"#,
        a.event_id
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: Uuid,
}

/// `meeting_delete` : effacer une rencontre de MA mémoire (l'autre garde la
/// sienne).
async fn meeting_delete(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Id = parse(args)?;
    sqlx::query!("delete from public.meetings where id = $1 and user_id = $2", a.id, moi)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}
