//! **Publier** — une story, une Vibe dans sa bibliothèque — et relire ce
//! qui a été publié ; l'accès restreint à ma bibliothèque.
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use super::enumeration;
use crate::acces::{self, q};
use crate::carte::ancre;
use crate::comptes::cuisine::profil_vu;
use crate::fichiers::regles::premier_dossier;

ops![
    publish_story => publish_story,
    publish_to_library => publish_to_library,
    library_access_list => library_access_list,
    library_access_grant => library_access_grant,
    library_access_revoke => library_access_revoke,
    library_item_get => library_item_get,
    library_items_of => library_items_of,
    story_get => story_get,
    stories_list => stories_list,
];

fn faux() -> Option<bool> {
    Some(false)
}
fn ami() -> Option<String> {
    Some("friend".into())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Story {
    p_story_id: Uuid,
    p_card_type: Option<String>,
    p_front_path: Option<String>,
    p_back_path: Option<String>,
    p_front_is_video: Option<bool>,
    p_back_is_video: Option<bool>,
    p_shareable: Option<bool>,
    p_media_key: Option<String>,
    #[serde(default = "faux")]
    p_saveable: Option<bool>,
    #[serde(default = "ami")]
    p_min_tier: Option<String>,
}

/// `publish_story` : une story (24 h), avec son audience minimale.
async fn publish_story(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Story = parse(args)?;
    let type_ = enumeration(ctx.db(), "card_type", a.p_card_type.as_deref()).await?;
    let palier = enumeration(ctx.db(), "friendship_tier", a.p_min_tier.as_deref()).await?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    sqlx::query!(
        "insert into public.contents (id, owner_id, context, shareable, saveable) values ($1, $2, 'story', coalesce($3, false), coalesce($4, false))",
        a.p_story_id,
        moi,
        a.p_shareable,
        a.p_saveable
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!(
        "insert into public.stories (id, owner_id, card_type, front_path, back_path, front_is_video, back_is_video, min_tier)
         values ($1, $2, $3::text::public.card_type, $4, $5, coalesce($6, false), coalesce($7, false),
                 coalesce($8::text::public.friendship_tier, 'friend'))",
        a.p_story_id,
        moi,
        type_,
        a.p_front_path,
        a.p_back_path,
        a.p_front_is_video,
        a.p_back_is_video,
        palier
    )
    .execute(ctx.db())
    .await?;
    sqlx::query!("insert into public.content_media_keys (content_id, media_key) values ($1, $2)", a.p_story_id, a.p_media_key)
        .execute(ctx.db())
        .await?;
    Ok(json!(a.p_story_id))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Publication {
    p_item_id: Uuid,
    p_kind: Option<String>,
    p_card_type: Option<String>,
    p_media: Option<Value>,
    p_caption: Option<String>,
    p_is_public: Option<bool>,
    p_shareable: Option<bool>,
    p_saveable: Option<bool>,
    p_media_key: Option<String>,
    #[serde(default)]
    p_aspect_w: Option<i16>,
    #[serde(default)]
    p_aspect_h: Option<i16>,
    #[serde(default)]
    p_caption_font: Option<String>,
    #[serde(default)]
    p_anchor_lat: Option<f64>,
    #[serde(default)]
    p_anchor_lng: Option<f64>,
}

/// Un média d'une publication, lu comme la base le lisait (mêmes
/// conversions, mêmes refus pour une valeur mal écrite).
struct Media {
    path: Option<String>,
    poster: Option<String>,
    is_video: bool,
    duree: Option<i32>,
}

async fn lire_media(db: &mut sqlx::PgConnection, m: &Value) -> NvResult<Media> {
    let r = sqlx::query!(
        r#"select $1::jsonb ->> 'path' as path, $1::jsonb ->> 'poster_path' as poster,
                  coalesce(($1::jsonb ->> 'is_video')::boolean, false) as "is_video!",
                  ($1::jsonb ->> 'duration_ms')::integer as duree"#,
        m
    )
    .fetch_one(db)
    .await?;
    Ok(Media { path: r.path, poster: r.poster, is_video: r.is_video, duree: r.duree })
}

/// Hors de MON dossier (`<moi>/…`) ? Un chemin sans dossier passe — comme
/// avant (`storage.foldername(chemin)[1]` valait alors `null`).
fn hors_de_mon_dossier(chemin: &str, moi: &str) -> bool {
    premier_dossier(chemin).is_some_and(|d| d != moi)
}

/// `publish_to_library` : une Vibe publiée dans ma bibliothèque (depuis la
/// file native de publication). Le format, les médias et leurs chemins
/// sont vérifiés ici ; les octets l'ont été au dépôt.
async fn publish_to_library(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Publication = parse(args)?;
    let genre = enumeration(ctx.db(), "library_kind", a.p_kind.as_deref()).await?;
    let type_ = enumeration(ctx.db(), "card_type", a.p_card_type.as_deref()).await?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let Some(Value::Array(medias)) = &a.p_media else { return Err(NvError::refused("Médias manquants")) };
    let n = medias.len();
    match genre.as_deref() {
        Some("card") if !(1..=2).contains(&n) => return Err(NvError::refused("Une Card a une ou deux faces")),
        Some("album") if !(1..=20).contains(&n) => return Err(NvError::refused("Une publication contient de 1 à 20 médias")),
        Some("flow") => {
            let video = match medias.first() {
                Some(m) if n == 1 => lire_media(ctx.db(), m).await?.is_video,
                _ => false,
            };
            if !video {
                return Err(NvError::refused("Un Flow est une vidéo, et une seule"));
            }
        }
        _ => {}
    }
    let (lat, lng) = match (a.p_anchor_lat, a.p_anchor_lng) {
        (Some(la), Some(lo)) => ancre::gommer(ctx.db(), la, lo).await?,
        _ => (None, None),
    };
    sqlx::query!(
        "insert into public.contents (id, owner_id, context, shareable, saveable, anchor_lat, anchor_lng)
         values ($1, $2, 'publication', coalesce($3, false), coalesce($4, false), $5, $6)",
        a.p_item_id,
        moi,
        a.p_shareable,
        a.p_saveable,
        lat,
        lng
    )
    .execute(ctx.db())
    .await?;
    let format_libre = matches!(genre.as_deref(), Some("album" | "flow"));
    sqlx::query!(
        "insert into public.library_items (id, owner_id, kind, card_type, caption, caption_font, is_public, aspect_w, aspect_h)
         values ($1, $2, $3::text::public.library_kind, coalesce($4::text::public.card_type, 'standard'),
                 nullif($5, ''), nullif($6, ''), coalesce($7, false), $8, $9)",
        a.p_item_id,
        moi,
        genre,
        type_,
        a.p_caption,
        a.p_caption_font,
        a.p_is_public,
        a.p_aspect_w.filter(|_| format_libre),
        a.p_aspect_h.filter(|_| format_libre)
    )
    .execute(ctx.db())
    .await?;
    let moi_texte = moi.to_string();
    let limite = if genre.as_deref() == Some("flow") { 180_000 } else { 60_000 };
    for (slot, brut) in medias.iter().enumerate() {
        let m = lire_media(ctx.db(), brut).await?;
        if m.path.as_deref().is_none_or(|p| hors_de_mon_dossier(p, &moi_texte)) {
            return Err(NvError::refused("Chemin de média hors du dossier du propriétaire"));
        }
        if m.poster.as_deref().is_some_and(|p| hors_de_mon_dossier(p, &moi_texte)) {
            return Err(NvError::refused("Chemin de couverture hors du dossier du propriétaire"));
        }
        if m.is_video && m.duree.is_some_and(|d| d > limite) {
            return Err(NvError::refused(if limite == 180_000 {
                "Une vidéo dure au plus trois minutes "
            } else {
                "Une vidéo dure au plus une minute "
            }));
        }
        sqlx::query!(
            "insert into public.library_media (item_id, owner_id, slot, path, is_video, duration_ms, poster_path, width, height)
             values ($1, $2, $3, $4, $5, $6, $7, ($8::jsonb ->> 'width')::integer, ($8::jsonb ->> 'height')::integer)",
            a.p_item_id,
            moi,
            i16::try_from(slot).unwrap_or(i16::MAX),
            m.path,
            m.is_video,
            m.duree.filter(|_| m.is_video),
            m.poster.filter(|_| m.is_video),
            brut
        )
        .execute(ctx.db())
        .await?;
    }
    sqlx::query!("insert into public.content_media_keys (content_id, media_key) values ($1, $2)", a.p_item_id, a.p_media_key)
        .execute(ctx.db())
        .await?;
    Ok(json!(a.p_item_id))
}

// ─── L'accès restreint à ma bibliothèque ──────────────────────────────────

/// `library_access_list` : ceux à qui j'ai ouvert ma bibliothèque.
async fn library_access_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('grantee_id', grantee_id)), '[]'::json) as "j!"
             from public.library_access where owner_id = $1"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Acces {
    grantee_id: Uuid,
}

/// `library_access_grant` : ouvrir ma bibliothèque à un ami.
async fn library_access_grant(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Acces = parse(args)?;
    if !acces::sont_amis(ctx.db(), moi, a.grantee_id).await? {
        return Err(NvError::refused("On n'ouvre sa bibliothèque qu'à un ami."));
    }
    sqlx::query!("insert into public.library_access (owner_id, grantee_id) values ($1, $2)", moi, a.grantee_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

/// `library_access_revoke` : la refermer.
async fn library_access_revoke(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Acces = parse(args)?;
    sqlx::query!("delete from public.library_access where owner_id = $1 and grantee_id = $2", moi, a.grantee_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

// ─── Relire ce qui a été publié ────────────────────────────────────────────

/// Les médias d'une publication (`li` : sa ligne), dans l'ordre de leurs
/// cases.
fn medias(li: &str) -> String {
    format!("coalesce((select jsonb_agg(to_jsonb(pm_) order by pm_.slot) from public.library_media pm_ where pm_.item_id = {li}.id), '[]'::jsonb)")
}

/// Ce qu'un contenu permet.
fn permissions(id: &str) -> String {
    format!("(select jsonb_build_object('shareable', pc_.shareable, 'saveable', pc_.saveable) from public.contents pc_ where pc_.id = {id})")
}

/// **Une publication telle que l'app la lit** (`li` : sa ligne de
/// `library_items`) : ses colonnes, ce qu'elle permet (`contents`) et ses
/// médias (`library_media`) — la forme de la bibliothèque et du fil.
pub(crate) fn publication_complete(li: &str) -> String {
    format!(
        "(to_jsonb({li}) || jsonb_build_object('contents', {perm}, 'library_media', {med}))",
        perm = permissions(&format!("{li}.id")),
        med = medias(li)
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: Uuid,
}

/// `library_item_get` : une publication et ses médias, ou `null`.
async fn library_item_get(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Id = parse(args)?;
    let sql = format!(
        "select to_jsonb(li) || jsonb_build_object('library_media', {med})
           from public.library_items li where li.id = $1::uuid and {aud}",
        med = medias("li"),
        aud = q::audience_publication("li.id", "$2::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.id).bind(moi).fetch_optional(ctx.db()).await?.unwrap_or(Value::Null))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnProprietaire {
    owner_id: Uuid,
}

/// `library_items_of` : les Vibes publiées d'une bibliothèque que je peux
/// voir, la plus récente d'abord (le seul format : `kind = 'card'`).
async fn library_items_of(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnProprietaire = parse(args)?;
    let sql = format!(
        "select coalesce(jsonb_agg({complete} order by li.created_at desc), '[]'::jsonb)
           from public.library_items li
          where li.owner_id = $1::uuid and li.kind = 'card' and {aud}",
        complete = publication_complete("li"),
        aud = q::audience_publication("li.id", "$2::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.owner_id).bind(moi).fetch_one(ctx.db()).await?)
}

/// Le profil de l'auteur d'une story, s'il m'est visible.
fn auteur(s: &str, moi: &str) -> String {
    format!(
        "(select {vu} from public.profiles p where p.id = {s}.owner_id and {peut})",
        vu = profil_vu("p", moi),
        peut = q::peut_voir_profil(moi, "p.id")
    )
}

/// `story_get` : une story et son auteur, ou `null`.
async fn story_get(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Id = parse(args)?;
    let sql = format!(
        "select to_jsonb(s) || jsonb_build_object('profiles', {auteur})
           from public.stories s where s.id = $1::uuid and {aud}",
        auteur = auteur("s", "$2::uuid"),
        aud = q::audience_story("s.id", "$2::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.id).bind(moi).fetch_optional(ctx.db()).await?.unwrap_or(Value::Null))
}

/// `stories_list` : les stories que je peux voir (non expirées), de la plus
/// ancienne à la plus récente, avec ce qu'elles permettent et leur auteur.
async fn stories_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    let sql = format!(
        "select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('contents', {perm}, 'profiles', {auteur})
                  order by s.created_at), '[]'::jsonb)
           from public.stories s where {aud}",
        perm = permissions("s.id"),
        auteur = auteur("s", "$1::uuid"),
        aud = q::audience_story("s.id", "$1::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(ctx.db()).await?)
}
