//! Ce qui est commun aux CONTENUS (stories et publications) : leur clé,
//! leurs vues, leurs likes, leur partage dans une conversation, leur
//! retrait — et le lieu de prise d'un objet.
//!
//! Toutes les lectures passent par la même question d'accès,
//! `acces::q::audience_contenu` (ex-`private.content_audience`).
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::parse;
use nv_core::{ops, Ctx, NvError, NvResult};

use crate::acces::{self, q};
use crate::conversations::messages::{self, Nouveau};

ops![
    open_content_media => open_content_media,
    record_content_view => record_content_view,
    content_viewers => content_viewers,
    content_viewer_count => content_viewer_count,
    toggle_like => toggle_like,
    content_likers => content_likers,
    content_likes_summary => content_likes_summary,
    share_content => share_content,
    revoked_contents => revoked_contents,
    library_media_keys => library_media_keys,
    content_flags => content_flags,
    content_delete => content_delete,
    capture_place_record => capture_place_record,
    capture_place_get => capture_place_get,
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnContenu {
    p_content_id: Uuid,
}

/// `open_content_media` : la clé d'un contenu, à qui est dans son audience.
async fn open_content_media(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnContenu = parse(args)?;
    if !acces::audience_contenu(ctx.db(), a.p_content_id, moi).await? {
        return Err(NvError::refused("Contenu introuvable"));
    }
    let cle = sqlx::query_scalar!("select media_key from public.content_media_keys where content_id = $1", a.p_content_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Contenu indisponible : sa clé n'a jamais été déposée"))?;
    Ok(json!(cle))
}

/// `record_content_view` : je note que j'ai vu ce contenu (sauf le mien).
async fn record_content_view(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnContenu = parse(args)?;
    let auteur = sqlx::query_scalar!("select owner_id from public.contents where id = $1", a.p_content_id)
        .fetch_optional(ctx.db())
        .await?;
    let Some(auteur) = auteur else { return Err(NvError::refused("Contenu introuvable")) };
    if !acces::audience_contenu(ctx.db(), a.p_content_id, moi).await? {
        return Err(NvError::refused("Contenu introuvable"));
    }
    if auteur != moi {
        sqlx::query!(
            "insert into public.content_views (content_id, viewer_id) values ($1, $2)
             on conflict (content_id, viewer_id) do update
               set view_count = content_views.view_count + 1, last_viewed_at = now()",
            a.p_content_id,
            moi
        )
        .execute(ctx.db())
        .await?;
    }
    Ok(Value::Null)
}

/// `content_viewers` : qui a vu MON contenu (ceux dont je peux voir le
/// profil), le plus récent d'abord.
async fn content_viewers(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnContenu = parse(args)?;
    let sql = format!(
        "select coalesce(json_agg(json_build_object('viewer_id', cv.viewer_id, 'display_name', p.display_name,
                  'tag_name', p.pseudo_shown, 'avatar_url', p.avatar_url, 'first_viewed_at', cv.first_viewed_at)
                  order by cv.first_viewed_at desc), '[]'::json)
           from public.content_views cv join public.profiles p on p.id = cv.viewer_id
          where cv.content_id = $1::uuid
            and exists (select 1 from public.contents c where c.id = $1::uuid and c.owner_id = $2::uuid)
            and {}",
        q::peut_voir_profil("$2::uuid", "cv.viewer_id")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.p_content_id).bind(moi).fetch_one(ctx.db()).await?)
}

/// `content_viewer_count` : combien de personnes ont vu MON contenu.
async fn content_viewer_count(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnContenu = parse(args)?;
    let n = sqlx::query_scalar!(
        r#"select count(*)::int as "n!" from public.content_views v
            where v.content_id = $1 and exists (select 1 from public.contents c where c.id = $1 and c.owner_id = $2)"#,
        a.p_content_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    Ok(json!(n))
}

/// `toggle_like` : j'aime / je n'aime plus.
///
/// Dans l'ordre de l'ancienne base : mon like ne se retire que si le
/// contenu m'est encore visible (la règle de lecture s'appliquait aussi à
/// la suppression) ; sinon on en pose un — suspension d'abord, audience
/// ensuite.
async fn toggle_like(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Authentification requise"))?;
    let a: UnContenu = parse(args)?;
    let c = a.p_content_id;
    let visible = acces::audience_contenu(ctx.db(), c, moi).await?;
    let retire = visible
        && sqlx::query!("delete from public.content_likes where content_id = $1 and user_id = $2", c, moi)
            .execute(ctx.db())
            .await?
            .rows_affected()
            > 0;
    if !retire {
        acces::refuser_si_suspendu(ctx.db(), moi).await?;
        if !visible {
            return Err(NvError::refused("Contenu introuvable"));
        }
        sqlx::query!("insert into public.content_likes (content_id, user_id) values ($1, $2)", c, moi)
            .execute(ctx.db())
            .await?;
    }
    let likes = sqlx::query_scalar!(r#"select count(*)::int as "n!" from public.content_likes where content_id = $1"#, c)
        .fetch_one(ctx.db())
        .await?;
    Ok(json!([{ "likes": likes, "liked": !retire }]))
}

/// `content_likers` : qui a aimé ce contenu (200 au plus, le plus récent
/// d'abord) — pour qui est dans son audience.
async fn content_likers(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnContenu = parse(args)?;
    let sql = format!(
        "select coalesce(json_agg(t order by t.liked_at desc), '[]'::json) from (
           select p.id, p.display_name, p.avatar_url, l.created_at as liked_at
             from public.content_likes l join public.profiles p on p.id = l.user_id
            where l.content_id = $1::uuid and {}
            order by l.created_at desc limit 200) t",
        q::audience_contenu("$1::uuid", "$2::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.p_content_id).bind(moi).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Plusieurs {
    p_ids: Vec<Uuid>,
}

/// `content_likes_summary` : pour chaque contenu, ses likes et le mien —
/// comptés seulement si je suis dans son audience (l'ancienne règle de
/// lecture des likes).
async fn content_likes_summary(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Plusieurs = parse(args)?;
    let sql = format!(
        "select coalesce(json_agg(json_build_object(
                  'content_id', i.id,
                  'likes', case when v.vu then (select count(*)::int from public.content_likes l where l.content_id = i.id) else 0 end,
                  'liked', v.vu and exists (select 1 from public.content_likes l where l.content_id = i.id and l.user_id = $1::uuid))
                order by i.n), '[]'::json)
           from unnest($2::uuid[]) with ordinality as i(id, n)
           cross join lateral (select {} as vu) v",
        q::audience_contenu("i.id", "$1::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(&a.p_ids).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Partage {
    p_content_id: Uuid,
    p_conversation_id: Uuid,
}

/// `share_content` : partager un contenu dans une conversation — chaque
/// membre (non bloqué) reçoit le droit de le voir, et un message l'annonce.
async fn share_content(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Partage = parse(args)?;
    let c = sqlx::query!(
        r#"select shareable, context::text as "context!", owner_id from public.contents where id = $1 and revoked_at is null"#,
        a.p_content_id
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Contenu introuvable"))?;
    if c.context == "direct" || c.context == "conversation_library" || !c.shareable {
        return Err(NvError::refused("Ce contenu n'est pas partageable"));
    }
    if !acces::audience_contenu(ctx.db(), a.p_content_id, moi).await? {
        return Err(NvError::refused("Contenu introuvable"));
    }
    if !acces::membre_conversation(ctx.db(), a.p_conversation_id, moi).await? {
        return Err(NvError::refused("Conversation introuvable"));
    }
    let sql = format!(
        "insert into public.content_grants (content_id, grantee_id, granted_by, conversation_id)
         select $1::uuid, m.user_id, $2::uuid, $3::uuid from public.conversation_members m
          where m.conversation_id = $3::uuid and m.user_id <> $2::uuid and not {} and not {}",
        q::est_bloque("$2::uuid", "m.user_id"),
        q::est_bloque("$4::uuid", "m.user_id")
    );
    let ajoutes = sqlx::query(&sql)
        .bind(a.p_content_id)
        .bind(moi)
        .bind(a.p_conversation_id)
        .bind(c.owner_id)
        .execute(ctx.db())
        .await?
        .rows_affected();
    messages::ecrire(
        ctx.db(),
        Nouveau {
            conversation_id: a.p_conversation_id,
            sender_id: moi,
            kind: Some("content_share"),
            content_id: Some(a.p_content_id),
            ..Default::default()
        },
    )
    .await?;
    Ok(json!(ajoutes))
}

/// `revoked_contents` : parmi ces contenus, ceux qui ont été retirés.
async fn revoked_contents(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    ctx.actor.uid()?;
    let a: Plusieurs = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(id), '[]'::json) as "j!" from public.contents where id = any($1) and revoked_at is not null"#,
        &a.p_ids
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnProprietaire {
    p_owner_id: Uuid,
}

/// `library_media_keys` : les clés des publications d'une bibliothèque que
/// je peux voir.
async fn library_media_keys(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnProprietaire = parse(args)?;
    let sql = format!(
        "select coalesce(json_agg(json_build_object('content_id', k.content_id, 'media_key', k.media_key)), '[]'::json)
           from public.content_media_keys k join public.library_items li on li.id = k.content_id
          where li.owner_id = $1::uuid and {}",
        q::audience_contenu("li.id", "$2::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.p_owner_id).bind(moi).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: Uuid,
}

/// `content_flags` (ex-lecture directe de `contents`) : le contexte d'un
/// contenu et ce qu'il permet — ou `null` s'il ne m'est pas visible.
async fn content_flags(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Id = parse(args)?;
    let sql = format!(
        "select json_build_object('context', c.context, 'shareable', c.shareable, 'saveable', c.saveable)
           from public.contents c where c.id = $1::uuid and (c.owner_id = $2::uuid or {})",
        q::audience_contenu("c.id", "$2::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.id).bind(moi).fetch_optional(ctx.db()).await?.unwrap_or(Value::Null))
}

/// `content_delete` (ex-suppression directe) : je retire MON contenu — la
/// base emporte sa story ou sa publication, ses clés, ses vues.
async fn content_delete(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Id = parse(args)?;
    sqlx::query!("delete from public.contents where id = $1 and owner_id = $2", a.id, moi)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Lieu {
    object_id: Uuid,
    owner_id: Option<Uuid>,
    taken_at: DateTime<Utc>,
    lat: Option<f64>,
    lon: Option<f64>,
}

/// `capture_place_record` : le lieu de prise de MON objet, noté une seule
/// fois (une seconde fois est refusée, comme avant — l'app n'en tient pas
/// compte).
async fn capture_place_record(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Lieu = parse(args)?;
    if a.owner_id != Some(moi) {
        return Err(NvError::refused("On ne note que le lieu de ses propres prises."));
    }
    sqlx::query!(
        "insert into public.capture_places (object_id, owner_id, taken_at, lat, lon) values ($1, $2, $3, $4, $5)",
        a.object_id,
        moi,
        a.taken_at,
        a.lat,
        a.lon
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnObjet {
    object_id: Uuid,
}

/// `capture_place_get` : le lieu de prise de MON objet, ou `null`.
async fn capture_place_get(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnObjet = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select to_json(c) as "j!" from public.capture_places c where c.object_id = $1 and c.owner_id = $2"#,
        a.object_id,
        moi
    )
    .fetch_optional(ctx.db())
    .await?
    .unwrap_or(Value::Null))
}
