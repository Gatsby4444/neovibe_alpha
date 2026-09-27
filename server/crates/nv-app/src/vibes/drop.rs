//! Le **Drop** d'une conversation (`library_vibes`) : chacun y dépose des
//! Vibes prises à la caméra, révélées à tous à 18 h 30 (ou tout de suite
//! dans une soirée).
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::parse;
use nv_core::{ops, Ctx, NvError, NvResult};

use super::enumeration;
use crate::acces::{self, q, vrai, P};
use crate::conversations::messages::{self, Nouveau};

ops![
    add_vibe_to_library => add_vibe_to_library,
    get_library_vibe_key => get_library_vibe_key,
    drop_keys => drop_keys,
    update_drop_vibe => update_drop_vibe,
    delete_drop_vibe => delete_drop_vibe,
    hide_drop_vibe => hide_drop_vibe,
    library_vibes_list => library_vibes_list,
];

const TITRE_MAX: usize = 60;

/// Le titre d'une Vibe du Drop : rogné de ses espaces (comme `btrim`), vide =
/// aucun, 60 caractères au plus.
fn titre(brut: Option<&str>) -> NvResult<Option<String>> {
    let t = brut.map(|t| t.trim_matches(' ')).filter(|t| !t.is_empty());
    if t.is_some_and(|t| t.chars().count() > TITRE_MAX) {
        return Err(NvError::refused("Titre trop long (60 caractères au plus)"));
    }
    Ok(t.map(str::to_owned))
}

/// **Le reveal du Drop** (ex-`library_reveal_at`) : 18 h 30, heure du
/// fuseau de la conversation — aujourd'hui si 18 h 30 n'est pas passé,
/// demain sinon. Calculé par la base (ses fuseaux horaires) ; `None` si le
/// fuseau manque.
pub async fn reveal_du_jour(
    db: &mut sqlx::PgConnection,
    fuseau: Option<String>,
    a: chrono::DateTime<chrono::Utc>,
) -> NvResult<Option<chrono::DateTime<chrono::Utc>>> {
    Ok(sqlx::query_scalar!(
        "select case when ($1::timestamptz at time zone $2)::time < time '18:30'
                     then (($1::timestamptz at time zone $2)::date + time '18:30') at time zone $2
                     else ((($1::timestamptz at time zone $2)::date + 1) + time '18:30') at time zone $2 end",
        a,
        fuseau
    )
    .fetch_one(db)
    .await?)
}

fn standard() -> Option<String> {
    Some("standard".into())
}
fn faux() -> Option<bool> {
    Some(false)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Depot {
    p_id: Uuid,
    p_conversation_id: Uuid,
    p_placeholder_path: Option<String>,
    p_sealed_path: Option<String>,
    p_media_key: Option<String>,
    #[serde(default = "standard")]
    p_card_type: Option<String>,
    #[serde(default = "faux")]
    p_front_is_video: Option<bool>,
    #[serde(default = "faux")]
    p_back_is_video: Option<bool>,
    #[serde(default = "faux")]
    p_saveable_by_others: Option<bool>,
    #[serde(default = "faux")]
    p_ephemeral: Option<bool>,
    #[serde(default)]
    p_placeholder_back_path: Option<String>,
    #[serde(default)]
    p_sealed_back_path: Option<String>,
    #[serde(default)]
    p_challenge_id: Option<Uuid>,
    #[serde(default)]
    p_title: Option<String>,
    #[serde(default)]
    p_camera_only: Option<bool>,
}

/// `add_vibe_to_library` : déposer une Vibe dans le Drop d'une conversation.
async fn add_vibe_to_library(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Depot = parse(args)?;
    let type_ = enumeration(ctx.db(), "card_type", a.p_card_type.as_deref()).await?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    if !acces::membre_conversation(ctx.db(), a.p_conversation_id, moi).await? {
        return Err(NvError::refused("Conversation introuvable"));
    }
    if matches!(type_.as_deref(), Some("bereal" | "one_of_one")) {
        return Err(NvError::refused("Ce type de vibe n'entre pas en bibliotheque"));
    }
    if a.p_camera_only != Some(true) {
        return Err(NvError::refused("Le Drop n'accepte que des photos ou vidéos prises à la caméra"));
    }
    let titre = titre(a.p_title.as_deref())?;
    let conv = sqlx::query!(
        r#"select library_timezone, conversation_type::text as "type_!" from public.conversations where id = $1"#,
        a.p_conversation_id
    )
    .fetch_optional(ctx.db())
    .await?;
    let soiree = conv.as_ref().is_some_and(|c| c.type_ == "event");
    let reveal: Option<chrono::DateTime<chrono::Utc>> = if soiree {
        let e = sqlx::query!("select id, closed_at from public.events where conversation_id = $1", a.p_conversation_id)
            .fetch_optional(ctx.db())
            .await?;
        let Some(e) = e.filter(|e| e.closed_at.is_none()) else {
            return Err(NvError::refused("Cet événement est terminé : son Drop est fermé"));
        };
        let present = sqlx::query_scalar!(
            r#"select exists (select 1 from public.event_presences where event_id = $1 and user_id = $2 and left_at is null) as "b!""#,
            e.id,
            moi
        )
        .fetch_one(ctx.db())
        .await?;
        if !present {
            return Err(NvError::refused("Tu n'es plus dans cet événement : son Drop t'est fermé"));
        }
        if let Some(defi) = a.p_challenge_id {
            let existe = sqlx::query_scalar!(
                r#"select exists (select 1 from public.event_challenges c where c.id = $1 and c.event_id = $2) as "b!""#,
                defi,
                e.id
            )
            .fetch_one(ctx.db())
            .await?;
            if !existe {
                return Err(NvError::refused("Défi introuvable"));
            }
        }
        Some(ctx.now)
    } else {
        if a.p_challenge_id.is_some() {
            return Err(NvError::refused("Un défi appartient à un événement"));
        }
        let maintenant = ctx.now;
        reveal_du_jour(ctx.db(), conv.map(|c| c.library_timezone), maintenant).await?
    };
    let gardable = if soiree { a.p_ephemeral.map(|e| !e) } else { a.p_saveable_by_others };
    let vibe = sqlx::query_scalar!(
        r#"insert into public.library_vibes as v (id, conversation_id, author_id, reveal_at, card_type, front_is_video, back_is_video,
                                                  saveable_by_others, ephemeral, placeholder_path, sealed_path,
                                                  placeholder_back_path, sealed_back_path, challenge_id, title)
           values ($1, $2, $3, $4, $5::text::public.card_type, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
           returning to_json(v) as "j!""#,
        a.p_id,
        a.p_conversation_id,
        moi,
        reveal,
        type_,
        a.p_front_is_video,
        a.p_back_is_video,
        gardable,
        a.p_ephemeral,
        a.p_placeholder_path,
        a.p_sealed_path,
        a.p_placeholder_back_path,
        a.p_sealed_back_path,
        a.p_challenge_id,
        titre
    )
    .fetch_one(ctx.db())
    .await?;
    sqlx::query!("insert into public.library_vibe_keys (vibe_id, media_key) values ($1, $2)", a.p_id, a.p_media_key)
        .execute(ctx.db())
        .await?;
    messages::ecrire(
        ctx.db(),
        Nouveau { conversation_id: a.p_conversation_id, sender_id: moi, kind: Some("library_add"), ..Default::default() },
    )
    .await?;
    Ok(vibe)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneVibe {
    p_vibe_id: Uuid,
}

/// `get_library_vibe_key` : la clé d'une Vibe du Drop, après son reveal, à
/// un membre de la conversation.
async fn get_library_vibe_key(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UneVibe = parse(args)?;
    let v = sqlx::query!("select conversation_id, reveal_at from public.library_vibes where id = $1", a.p_vibe_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Vibe introuvable"))?;
    if !acces::membre_conversation(ctx.db(), v.conversation_id, moi).await? {
        return Err(NvError::refused("Vibe introuvable"));
    }
    if ctx.now < v.reveal_at {
        return Err(NvError::refused("Le reveal n'a pas encore eu lieu"));
    }
    let cle = sqlx::query_scalar!("select media_key from public.library_vibe_keys where vibe_id = $1", a.p_vibe_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Vibe indisponible : sa clé n'a jamais été déposée"))?;
    Ok(json!(cle))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneConversation {
    p_conversation_id: Uuid,
}

/// `drop_keys` : les clés de toutes les Vibes révélées d'un Drop, en une
/// fois.
async fn drop_keys(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UneConversation = parse(args)?;
    if !acces::membre_conversation(ctx.db(), a.p_conversation_id, moi).await? {
        return Ok(json!([]));
    }
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('vibe_id', v.id, 'media_key', k.media_key)), '[]'::json) as "j!"
             from public.library_vibes v join public.library_vibe_keys k on k.vibe_id = v.id
            where v.conversation_id = $1 and now() >= v.reveal_at"#,
        a.p_conversation_id
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reglages {
    p_vibe_id: Uuid,
    p_title: Option<String>,
    p_saveable_by_others: Option<bool>,
    p_ephemeral: Option<bool>,
}

/// `update_drop_vibe` : l'auteur change le titre et les réglages de sa Vibe.
/// Dans une soirée, « gardable » suit « éphémère » (l'un est l'inverse de
/// l'autre).
async fn update_drop_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Reglages = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let titre = titre(a.p_title.as_deref())?;
    let n = sqlx::query!(
        "update public.library_vibes v
            set title = $3,
                ephemeral = coalesce($5, v.ephemeral),
                saveable_by_others = case
                  when exists (select 1 from public.conversations c where c.id = v.conversation_id and c.conversation_type = 'event')
                    then not coalesce($5, v.ephemeral)
                  else coalesce($4, v.saveable_by_others) end
          where v.id = $1 and v.author_id = $2",
        a.p_vibe_id,
        moi,
        titre,
        a.p_saveable_by_others,
        a.p_ephemeral
    )
    .execute(ctx.db())
    .await?
    .rows_affected();
    if n == 0 {
        return Err(NvError::refused("Seul son auteur peut modifier cette Vibe"));
    }
    Ok(Value::Null)
}

/// `delete_drop_vibe` : l'auteur — ou l'organisateur de la soirée — retire
/// une Vibe du Drop.
async fn delete_drop_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UneVibe = parse(args)?;
    let v = sqlx::query!("select author_id, conversation_id from public.library_vibes where id = $1", a.p_vibe_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Vibe introuvable"))?;
    if v.author_id != moi
        && !vrai(ctx.db(), &q::organise_le_drop("$1::uuid", "$2::uuid"), &[P::U(v.conversation_id), P::U(moi)]).await?
    {
        return Err(NvError::refused("Seul son auteur ou l'organisateur peut supprimer cette Vibe"));
    }
    sqlx::query!("delete from public.library_vibes where id = $1", a.p_vibe_id).execute(ctx.db()).await?;
    Ok(Value::Null)
}

/// `hide_drop_vibe` : je ne veux plus voir cette Vibe (pour moi seul).
async fn hide_drop_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UneVibe = parse(args)?;
    let membre = sqlx::query_scalar!(
        r#"select exists (select 1 from public.library_vibes v
                            join public.conversation_members m on m.conversation_id = v.conversation_id and m.user_id = $2
                           where v.id = $1) as "b!""#,
        a.p_vibe_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if !membre {
        return Err(NvError::refused("Vibe introuvable"));
    }
    sqlx::query!(
        "insert into public.library_vibe_hidden (user_id, vibe_id) values ($1, $2) on conflict do nothing",
        moi,
        a.p_vibe_id
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ParConversation {
    conversation_id: Uuid,
}

/// `library_vibes_list` (ex-lecture directe) : les Vibes d'un Drop, la plus
/// récente d'abord — sauf celles que j'ai masquées.
async fn library_vibes_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: ParConversation = parse(args)?;
    if !acces::membre_conversation(ctx.db(), a.conversation_id, moi).await? {
        return Ok(json!([]));
    }
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(to_json(v) order by v.reveal_at desc, v.created_at desc, v.id), '[]'::json) as "j!"
             from public.library_vibes v
            where v.conversation_id = $1
              and not exists (select 1 from public.library_vibe_hidden h where h.vibe_id = v.id and h.user_id = $2)"#,
        a.conversation_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}
