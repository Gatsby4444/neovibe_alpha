//! **Signaler** — un contenu, un profil, une Vibe du Drop, une Vibe reçue,
//! une soirée. On ne signale que ce qu'on peut voir, jamais le sien ; un
//! doublon n'est pas une erreur (sauf pour un contenu ou un profil, comme
//! avant). Chaque signalement scelle sa preuve.
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use nv_core::args::parse;
use nv_core::{ops, Ctx, NvError, NvResult};

use super::preuves::{self, Cible};
use crate::acces::{self, q, vrai, P};

ops![
    report_sent_vibe => report_sent_vibe,
    report_drop_vibe => report_drop_vibe,
    report_event => report_event,
    content_report_create => content_report_create,
    profile_report_create => profile_report_create,
];

/// Les détails d'un signalement : rognés de leurs espaces, vides = aucun.
fn details(brut: Option<&str>) -> Option<&str> {
    brut.map(|d| d.trim_matches(' ')).filter(|d| !d.is_empty())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VibeEnvoyee {
    p_card_id: Uuid,
    p_reason: Option<String>,
    p_details: Option<String>,
}

/// `report_sent_vibe` : signaler une Vibe qu'on m'a envoyée.
async fn report_sent_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: VibeEnvoyee = parse(args)?;
    let auteur = sqlx::query_scalar!("select owner_id from public.cards where id = $1", a.p_card_id)
        .fetch_optional(ctx.db())
        .await?;
    let recue = vrai(ctx.db(), &q::a_recu_la_carte("$1::uuid", "$2::uuid"), &[P::U(a.p_card_id), P::U(moi)]).await?;
    let Some(auteur) = auteur.filter(|_| recue) else { return Err(NvError::refused("Vibe introuvable")) };
    if auteur == moi {
        return Err(NvError::refused("On ne signale pas sa propre Vibe"));
    }
    let id = sqlx::query_scalar!(
        "insert into public.card_reports (card_id, author_id, reporter_id, reason, details) values ($1, $2, $3, $4, $5)
         on conflict (card_id, reporter_id) do nothing returning id",
        a.p_card_id,
        auteur,
        moi,
        a.p_reason,
        details(a.p_details.as_deref())
    )
    .fetch_optional(ctx.db())
    .await?;
    if let Some(id) = id {
        preuves::sceller(ctx.db(), id, Cible::VibeEnvoyee(a.p_card_id)).await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VibeDuDrop {
    p_vibe_id: Uuid,
    p_reason: Option<String>,
    p_details: Option<String>,
}

/// `report_drop_vibe` : signaler une Vibe d'un Drop dont je suis membre.
async fn report_drop_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: VibeDuDrop = parse(args)?;
    let v = sqlx::query!("select conversation_id, author_id from public.library_vibes where id = $1", a.p_vibe_id)
        .fetch_optional(ctx.db())
        .await?;
    let v = match v {
        Some(v) if acces::membre_conversation(ctx.db(), v.conversation_id, moi).await? => v,
        _ => return Err(NvError::refused("Vibe introuvable")),
    };
    if v.author_id == moi {
        return Err(NvError::refused("On ne signale pas sa propre Vibe"));
    }
    let id = sqlx::query_scalar!(
        "insert into public.library_vibe_reports (vibe_id, conversation_id, author_id, reporter_id, reason, details)
         values ($1, $2, $3, $4, $5, $6) on conflict (vibe_id, reporter_id) do nothing returning id",
        a.p_vibe_id,
        v.conversation_id,
        v.author_id,
        moi,
        a.p_reason,
        details(a.p_details.as_deref())
    )
    .fetch_optional(ctx.db())
    .await?;
    if let Some(id) = id {
        preuves::sceller(ctx.db(), id, Cible::VibeDuDrop(a.p_vibe_id)).await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Soiree {
    p_event: Uuid,
    p_reason: Option<String>,
    p_details: Option<String>,
}

/// `report_event` : signaler une soirée que je peux voir (son affiche, sa
/// description).
async fn report_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Soiree = parse(args)?;
    let auteur = sqlx::query_scalar!("select created_by from public.events where id = $1", a.p_event)
        .fetch_optional(ctx.db())
        .await?;
    let visible = vrai(ctx.db(), &q::peut_voir_evenement("$1::uuid", "$2::uuid"), &[P::U(a.p_event), P::U(moi)]).await?;
    let Some(auteur) = auteur.filter(|_| visible) else { return Err(NvError::refused("Soirée introuvable")) };
    if auteur == moi {
        return Err(NvError::refused("On ne signale pas sa propre soirée"));
    }
    let id = sqlx::query_scalar!(
        "insert into public.event_reports (event_id, author_id, reporter_id, reason, details) values ($1, $2, $3, $4, $5)
         on conflict (event_id, reporter_id) do nothing returning id",
        a.p_event,
        auteur,
        moi,
        a.p_reason,
        details(a.p_details.as_deref())
    )
    .fetch_optional(ctx.db())
    .await?;
    if let Some(id) = id {
        preuves::sceller(ctx.db(), id, Cible::Soiree(a.p_event)).await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Contenu {
    content_id: Uuid,
    reporter_id: Option<Uuid>,
    reason: Option<String>,
    #[serde(default)]
    details: Option<String>,
}

/// `content_report_create` (ex-écriture directe) : signaler un contenu que
/// je peux voir.
async fn content_report_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Contenu = parse(args)?;
    if a.reporter_id != Some(moi) || !acces::audience_contenu(ctx.db(), a.content_id, moi).await? {
        return Err(NvError::refused("On ne signale que ce qu'on peut voir, en son nom."));
    }
    let id = sqlx::query_scalar!(
        "insert into public.content_reports (content_id, reporter_id, reason, details) values ($1, $2, $3, $4) returning id",
        a.content_id,
        moi,
        a.reason,
        a.details
    )
    .fetch_one(ctx.db())
    .await?;
    preuves::sceller(ctx.db(), id, Cible::Contenu(a.content_id)).await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Profil {
    target_id: Uuid,
    reporter_id: Option<Uuid>,
    reason: Option<String>,
    #[serde(default)]
    details: Option<String>,
}

/// `profile_report_create` (ex-écriture directe) : signaler un profil.
async fn profile_report_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Profil = parse(args)?;
    if a.reporter_id != Some(moi) {
        return Err(NvError::refused("On ne signale qu'en son nom."));
    }
    sqlx::query!(
        "insert into public.profile_reports (target_id, reporter_id, reason, details) values ($1, $2, $3, $4)",
        a.target_id,
        moi,
        a.reason,
        a.details
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}
