//! **Pulse** — le fil (docs/serveur-rust.md, annexe A.6 ; docs/feed-pulse.md).
//!
//! Trois sources, toutes humaines :
//! 1. le contenu public des gens **croisés** récemment ;
//! 2. ce que mes **amis ont ajouté** à mon fil (anonyme jusqu'à mon like) ;
//! 3. ce qui a été publié **autour de moi** (la règle partagée avec la carte,
//!    `carte::autour`).
//!
//! Rien de plus ancien que `feed_rules.freshness` ; 200 au plus ; le plus
//! récent d'abord — l'ordre vit dans [`rang`], seul endroit où brancher un
//! jour la pertinence.
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::parse;
use nv_core::{ops, Ctx, NvError, NvResult};

use crate::acces::{self, q};
use crate::carte::autour;
use crate::vibes::{enumeration, publication::publication_complete};

ops![
    feed_items => feed_items,
    feed_adders => feed_adders,
    add_to_feed => add_to_feed,
];

/// L'ordre du fil (ex-`private.feed_rank`) : aujourd'hui, la date de
/// publication.
fn rang(li: &str) -> String {
    format!("extract(epoch from {li}.created_at)")
}

fn tout() -> Option<String> {
    Some("all".into())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Fil {
    #[serde(default)]
    p_kind: Option<String>,
    #[serde(default = "tout")]
    p_mode: Option<String>,
    #[serde(default)]
    p_lat: Option<f64>,
    #[serde(default)]
    p_lng: Option<f64>,
}

/// `feed_items` : mon fil — `p_mode` choisit les sources (`all`, `friends`,
/// `around`), `p_kind` le format.
async fn feed_items(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Authentification requise"))?;
    let a: Fil = parse(args)?;
    let genre = enumeration(ctx.db(), "library_kind", a.p_kind.as_deref()).await?;
    let sql = format!(
        "with regles as (select freshness, around_radius_m from public.feed_rules where id),
         depuis as (select now() - r.freshness as t from regles r),
         croises as (
           select case when pp.user_low = $1::uuid then pp.user_high else pp.user_low end as autre
             from public.ping_pairs pp
            where (pp.user_low = $1::uuid or pp.user_high = $1::uuid) and pp.last_seen_at > now() - {fp}
           union
           select case when ec.user_low = $1::uuid then ec.user_high else ec.user_low end
             from public.event_crossings ec
            where (ec.user_low = $1::uuid or ec.user_high = $1::uuid) and ec.last_at > now() - {fe}
         ),
         candidats as (
           select ci.id from public.library_items ci
            where $2::text = 'all' and ci.is_public and ci.owner_id <> $1::uuid
              and ci.owner_id in (select autre from croises) and ci.created_at > (select t from depuis)
           union
           select fa.content_id from public.feed_adds fa join public.library_items fli on fli.id = fa.content_id
            where $2::text in ('all', 'friends') and fa.recipient_id = $1::uuid and fa.created_at > (select t from depuis)
              and not {bloque_ajout}
           union
           select v.id from ({autour}) v
            where $2::text in ('all', 'around') and v.owner_id <> $1::uuid
         )
         select coalesce(jsonb_agg(x.j order by x.rang desc), '[]'::jsonb) from (
           select {complete} as j, {rang} as rang
             from public.library_items li join candidats k on k.id = li.id
            where ($3::text is null or li.kind = $3::text::public.library_kind)
              and not {revoque} and not {bloque}
            order by {rang} desc limit 200) x",
        fp = q::fenetre("ping"),
        fe = q::fenetre("event"),
        bloque_ajout = q::est_bloque("fa.adder_id", "$1::uuid"),
        autour = autour::vibes_autour(
            "$1::uuid",
            "$4::float8",
            "$5::float8",
            "(select around_radius_m from regles)",
            "(select t from depuis)"
        ),
        complete = publication_complete("li"),
        rang = rang("li"),
        revoque = q::est_revoque("li.id"),
        bloque = q::est_bloque("li.owner_id", "$1::uuid"),
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql)
        .bind(moi)
        .bind(a.p_mode)
        .bind(genre)
        .bind(a.p_lat)
        .bind(a.p_lng)
        .fetch_one(ctx.db())
        .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Contenus {
    p_content_ids: Vec<Uuid>,
}

/// `feed_adders` : qui m'a ajouté ces contenus — révélé SEULEMENT pour ceux
/// que j'ai aimés (le like ouvre la conversation, docs/vision-produit.md).
async fn feed_adders(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Contenus = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('content_id', fa.content_id, 'adder_id', fa.adder_id,
                                                        'display_name', p.display_name)), '[]'::json) as "j!"
             from public.feed_adds fa join public.profiles p on p.id = fa.adder_id
            where fa.recipient_id = $1 and fa.content_id = any($2)
              and exists (select 1 from public.content_likes l where l.content_id = fa.content_id and l.user_id = $1)"#,
        moi,
        &a.p_content_ids
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ajout {
    p_content_id: Uuid,
    p_recipient_ids: Vec<Uuid>,
}

/// `add_to_feed` : ajouter une publication (partageable, que je vois) au fil
/// de mes amis — anonymement. Rend combien l'ont reçue (un ami qui l'avait
/// déjà ne compte pas).
async fn add_to_feed(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Authentification requise"))?;
    let a: Ajout = parse(args)?;
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    let auteur = sqlx::query_scalar!(
        "select owner_id from public.contents
          where id = $1 and context = 'publication' and revoked_at is null and shareable",
        a.p_content_id
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Ce contenu n'est pas partageable"))?;
    if !acces::audience_contenu(ctx.db(), a.p_content_id, moi).await? {
        return Err(NvError::refused("Contenu introuvable"));
    }
    let sql = format!(
        "insert into public.feed_adds (content_id, adder_id, recipient_id)
         select $1::uuid, $2::uuid, r from unnest($3::uuid[]) as r
          where r <> $2::uuid and {amis} and not {b1} and not {b2}
         on conflict (content_id, recipient_id) do nothing",
        amis = q::sont_amis("$2::uuid", "r"),
        b1 = q::est_bloque("$2::uuid", "r"),
        b2 = q::est_bloque("$4::uuid", "r"),
    );
    let n = sqlx::query(&sql)
        .bind(a.p_content_id)
        .bind(moi)
        .bind(&a.p_recipient_ids)
        .bind(auteur)
        .execute(ctx.db())
        .await?
        .rows_affected();
    Ok(json!(n))
}
