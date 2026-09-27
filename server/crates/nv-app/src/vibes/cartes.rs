//! Les Vibes ENVOYÉES (`cards`) : leur clé, leurs visionnages, les replays,
//! leur modification, leur envoi avec une demande d'ami, et ce que l'app
//! faisait directement sur `cards`, `card_deliveries` et
//! `friend_share_defaults`.
use serde::Deserialize;
use serde_json::{json, Map, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use super::livraisons;
use crate::acces::{self, q, vrai, P};

ops![
    set_card_media_key => set_card_media_key,
    open_card_media => open_card_media,
    mark_card_viewed => mark_card_viewed,
    grant_replay => grant_replay,
    request_replay => request_replay,
    update_sent_vibe => update_sent_vibe,
    delete_sent_vibe => delete_sent_vibe,
    request_connection_with_vibe => request_connection_with_vibe,
    card_get => card_get,
    card_create => card_create,
    card_delivery_create => card_delivery_create,
    card_deliveries_pending_replay => card_deliveries_pending_replay,
    card_replay_requests_mine => card_replay_requests_mine,
    card_delivery_mine => card_delivery_mine,
    friend_share_defaults_list => friend_share_defaults_list,
    friend_share_defaults_upsert => friend_share_defaults_upsert,
    friend_share_default_delete => friend_share_default_delete,
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cle {
    p_card_id: Uuid,
    p_media_key: Option<String>,
}

/// `set_card_media_key` : l'auteur dépose la clé de sa Vibe (une fois).
async fn set_card_media_key(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Cle = parse(args)?;
    let a_moi = sqlx::query_scalar!(
        r#"select exists (select 1 from public.cards where id = $1 and owner_id = $2) as "b!""#,
        a.p_card_id,
        ctx.actor.maybe_uid()
    )
    .fetch_one(ctx.db())
    .await?;
    if !a_moi {
        return Err(NvError::refused("Vibe introuvable"));
    }
    sqlx::query!(
        "insert into public.card_media_keys (card_id, media_key) values ($1, $2) on conflict (card_id) do nothing",
        a.p_card_id,
        a.p_media_key
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneCarte {
    p_card_id: Uuid,
}

/// `open_card_media` : la clé d'une Vibe — à son auteur, ou à un
/// destinataire à qui il reste des visionnages (compté ici).
async fn open_card_media(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: UneCarte = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    let c = sqlx::query!("select owner_id, max_views from public.cards where id = $1", a.p_card_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Vibe introuvable"))?;
    let cle = sqlx::query_scalar!("select media_key from public.card_media_keys where card_id = $1", a.p_card_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Vibe indisponible : sa clé n'a jamais été déposée"))?;
    if Some(c.owner_id) == moi {
        return Ok(json!(cle));
    }
    let d = sqlx::query!(
        "select id, destroyed_at, view_count, replay_granted_at from public.card_deliveries
          where card_id = $1 and recipient_id = $2 for update",
        a.p_card_id,
        moi
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Vibe introuvable"))?;
    if d.destroyed_at.is_some() {
        return Err(NvError::refused("Vibe détruite"));
    }
    let max = i64::from(c.max_views.unwrap_or(i32::MAX)) + i64::from(d.replay_granted_at.is_some());
    if i64::from(d.view_count) >= max {
        return Err(NvError::refused("Plus de visionnages disponibles"));
    }
    sqlx::query!(
        "update public.card_deliveries set view_count = view_count + 1, first_viewed_at = coalesce(first_viewed_at, now()) where id = $1",
        d.id
    )
    .execute(ctx.db())
    .await?;
    Ok(json!(cle))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Livraison {
    delivery_id: Uuid,
}

/// `mark_card_viewed` : un visionnage de plus (ancien chemin, sans clé).
async fn mark_card_viewed(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Livraison = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    let d = sqlx::query!(
        "select recipient_id, destroyed_at, view_count, replay_granted_at, card_id from public.card_deliveries where id = $1 for update",
        a.delivery_id
    )
    .fetch_optional(ctx.db())
    .await?;
    let Some(d) = d.filter(|d| Some(d.recipient_id) == moi) else { return Err(NvError::refused("Livraison introuvable")) };
    if d.destroyed_at.is_some() {
        return Err(NvError::refused("Card détruite"));
    }
    let c = sqlx::query!(r#"select card_type::text as "t!", max_views from public.cards where id = $1"#, d.card_id)
        .fetch_optional(ctx.db())
        .await?;
    let chaude = c.as_ref().is_some_and(|c| c.t == "hot");
    if chaude {
        if d.view_count >= 1 {
            return Err(NvError::refused("Une Card Hot ne peut être vue qu'une fois"));
        }
    } else {
        let max = i64::from(c.and_then(|c| c.max_views).unwrap_or(i32::MAX)) + i64::from(d.replay_granted_at.is_some());
        if i64::from(d.view_count) >= max {
            return Err(NvError::refused("Plus de visionnages disponibles"));
        }
    }
    sqlx::query!(
        "update public.card_deliveries set view_count = view_count + 1, first_viewed_at = coalesce(first_viewed_at, now()),
                hot_boosted = hot_boosted or ($2 and now() - delivered_at < interval '2 minutes') where id = $1",
        a.delivery_id,
        chaude
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `grant_replay` : l'auteur accorde un revisionnage demandé.
async fn grant_replay(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Livraison = parse(args)?;
    let d = sqlx::query!(
        "select cd.replay_requested_at, cd.replay_granted_at from public.card_deliveries cd join public.cards c on c.id = cd.card_id
          where cd.id = $1 and c.owner_id = $2 for update of cd",
        a.delivery_id,
        ctx.actor.maybe_uid()
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused("Livraison introuvable"))?;
    if d.replay_requested_at.is_none() || d.replay_granted_at.is_some() {
        return Err(NvError::refused("Aucune demande de replay en attente"));
    }
    sqlx::query!("update public.card_deliveries set replay_granted_at = now() where id = $1", a.delivery_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

/// `request_replay` : le destinataire demande à revoir une Vibe.
async fn request_replay(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Livraison = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    let d = sqlx::query!(
        "select recipient_id, card_id, replay_requested_at from public.card_deliveries where id = $1 for update",
        a.delivery_id
    )
    .fetch_optional(ctx.db())
    .await?;
    let Some(d) = d.filter(|d| Some(d.recipient_id) == moi) else { return Err(NvError::refused("Livraison introuvable")) };
    let chaude = sqlx::query_scalar!(r#"select card_type::text as "t!" from public.cards where id = $1"#, d.card_id)
        .fetch_optional(ctx.db())
        .await?
        .is_some_and(|t| t == "hot");
    if chaude {
        return Err(NvError::refused("Une Card Hot ne peut pas être revisionnée"));
    }
    if d.replay_requested_at.is_some() {
        return Err(NvError::refused("Replay déjà demandé"));
    }
    sqlx::query!("update public.card_deliveries set replay_requested_at = now() where id = $1", a.delivery_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reglages {
    p_card_id: Uuid,
    p_max_views: Option<i32>,
    p_view_duration_seconds: Option<i32>,
    p_scrubbable: Option<bool>,
    p_saveable: Option<bool>,
}

/// `update_sent_vibe` : l'auteur change les réglages d'une Vibe envoyée.
async fn update_sent_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Reglages = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    if let Some(m) = moi {
        acces::refuser_si_suspendu(ctx.db(), m).await?;
    }
    let existe = sqlx::query_scalar!(
        r#"select exists (select 1 from public.cards where id = $1 and owner_id = $2) as "b!""#,
        a.p_card_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if !existe {
        return Err(NvError::refused("Seul son auteur peut modifier cette Vibe"));
    }
    sqlx::query!(
        "update public.cards set max_views = $2,
                view_duration_seconds = case when card_type = 'oneshot' then null else $3::int end,
                scrubbable = coalesce($4, false),
                saveable = card_type <> 'one_of_one' and coalesce($5, false)
          where id = $1",
        a.p_card_id,
        a.p_max_views,
        a.p_view_duration_seconds,
        a.p_scrubbable,
        a.p_saveable
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `delete_sent_vibe` : l'auteur retire une Vibe envoyée (et ses messages).
async fn delete_sent_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: UneCarte = parse(args)?;
    let existe = sqlx::query_scalar!(
        r#"select exists (select 1 from public.cards where id = $1 and owner_id = $2) as "b!""#,
        a.p_card_id,
        ctx.actor.maybe_uid()
    )
    .fetch_one(ctx.db())
    .await?;
    if !existe {
        return Err(NvError::refused("Seul son auteur peut supprimer cette Vibe"));
    }
    sqlx::query!("delete from public.messages where card_id = $1", a.p_card_id).execute(ctx.db()).await?;
    sqlx::query!("delete from public.cards where id = $1", a.p_card_id).execute(ctx.db()).await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AvecDemande {
    peer: Option<Uuid>,
    p_card_id: Uuid,
}

/// `request_connection_with_vibe` : une Vibe envoyée AVEC une demande d'ami
/// à quelqu'un qu'on vient de croiser.
async fn request_connection_with_vibe(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Non authentifié"))?;
    let a: AvecDemande = parse(args)?;
    let pair = a.peer.filter(|p| *p != moi).ok_or_else(|| NvError::refused("Destinataire invalide"))?;
    let a_moi = sqlx::query_scalar!(
        r#"select exists (select 1 from public.cards c where c.id = $1 and c.owner_id = $2) as "b!""#,
        a.p_card_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if !a_moi {
        return Err(NvError::refused("Vibe introuvable"));
    }
    if acces::sont_amis(ctx.db(), moi, pair).await? {
        return Err(NvError::refused("Vous êtes déjà connectés"));
    }
    if !vrai(ctx.db(), &q::croises_recemment("$1::uuid", "$2::uuid"), &[P::U(moi), P::U(pair)]).await? {
        return Err(NvError::refused("Croisement non constaté"));
    }
    if acces::is_blocked(ctx.db(), moi, pair).await? {
        return Err(NvError::refused("Envoi impossible"));
    }
    let deja = sqlx::query_scalar!(
        "select id from public.connection_requests where sender_id = $1 and receiver_id = $2 and status = 'pending' and expires_at > now() limit 1",
        moi,
        pair
    )
    .fetch_optional(ctx.db())
    .await?;
    let demande = match deja {
        Some(id) => {
            sqlx::query!("update public.connection_requests set card_id = $2 where id = $1", id, a.p_card_id)
                .execute(ctx.db())
                .await?;
            id
        }
        None => {
            acces::refuser_si_suspendu(ctx.db(), moi).await?;
            sqlx::query_scalar!(
                "insert into public.connection_requests (sender_id, receiver_id, status, expires_at, card_id)
                 values ($1, $2, 'pending', now() + interval '7 days', $3) returning id",
                moi,
                pair,
                a.p_card_id
            )
            .fetch_one(ctx.db())
            .await?
        }
    };
    livraisons::livrer(ctx.db(), a.p_card_id, pair, None, true).await?;
    Ok(json!(demande))
}

// ─── Ce que l'app faisait directement sur les tables ───────────────────────

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: Uuid,
}

/// `card_get` : une Vibe que j'ai écrite ou reçue, ou `null`.
async fn card_get(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Id = parse(args)?;
    let sql = format!(
        "select to_json(c) from public.cards c where c.id = $2 and (c.owner_id = $1 or {})",
        q::a_recu_la_carte("c.id", "$1::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(a.id).fetch_optional(ctx.db()).await?.unwrap_or(Value::Null))
}

/// `card_create` : une nouvelle Vibe (la ligne). Les colonnes présentes sont
/// écrites telles quelles (`null` compris), les absentes prennent leur valeur
/// par défaut — comme l'ancien guichet.
async fn card_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let Value::Object(champs) = args else { return Err(NvError::BadArgs("un objet est attendu".into())) };
    if champs.get("owner_id").and_then(Value::as_str) != Some(moi.to_string().as_str()) {
        return Err(NvError::refused("On ne crée que ses propres Vibes."));
    }
    acces::refuser_si_suspendu(ctx.db(), moi).await?;
    const COLONNES: &[(&str, &str)] = &[
        ("id", "uuid"),
        ("owner_id", "uuid"),
        ("card_type", "public.card_type"),
        ("front_path", "text"),
        ("back_path", "text"),
        ("view_duration_seconds", "int4"),
        ("max_views", "int4"),
        ("saveable", "bool"),
        ("imported", "bool"),
        ("front_is_video", "bool"),
        ("back_is_video", "bool"),
        ("scrubbable", "bool"),
        ("encrypted", "bool"),
    ];
    inserer_ligne(ctx, "public.cards", COLONNES, &champs).await
}

/// Une insertion « comme l'ancien guichet » : seules les colonnes connues,
/// chacune convertie depuis le JSON par la base elle-même ; rend la ligne.
async fn inserer_ligne(ctx: &mut Ctx, table: &str, colonnes: &[(&str, &str)], champs: &Map<String, Value>) -> NvResult<Value> {
    for k in champs.keys() {
        if !colonnes.iter().any(|(c, _)| c == k) {
            return Err(NvError::BadArgs(format!("colonne inconnue : {k}")));
        }
    }
    let presentes: Vec<&(&str, &str)> = colonnes.iter().filter(|(c, _)| champs.contains_key(*c)).collect();
    let noms = presentes.iter().map(|(c, _)| *c).collect::<Vec<_>>().join(", ");
    // `->>` rend `null` pour un `null` JSON : la colonne reçoit alors `null`,
    // comme avant (une colonne ABSENTE, elle, prend sa valeur par défaut).
    let valeurs = presentes.iter().map(|(c, t)| format!("($1::jsonb ->> '{c}')::{t}")).collect::<Vec<_>>().join(", ");
    let sql = format!("insert into {table} as l ({noms}) values ({valeurs}) returning to_json(l)");
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(Value::Object(champs.clone())).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NouvelleLivraison {
    card_id: Uuid,
    recipient_id: Uuid,
    message_id: Option<Uuid>,
}

/// `card_delivery_create` : livrer ma Vibe à un ami — par le passage obligé.
async fn card_delivery_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: NouvelleLivraison = parse(args)?;
    // Même ordre que l'ancienne base : la règle des livraisons (déclencheur)
    // d'abord, puis « c'est bien ma Vibe » (politique).
    livraisons::regles(ctx.db(), a.card_id, a.recipient_id).await?;
    if !vrai(ctx.db(), &q::possede_carte("$1::uuid", "$2::uuid"), &[P::U(a.card_id), P::U(moi)]).await? {
        return Err(NvError::refused("On ne livre que ses propres Vibes."));
    }
    livraisons::inserer(ctx.db(), a.card_id, a.recipient_id, a.message_id, false).await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ParCarte {
    card_id: Uuid,
}

/// `card_deliveries_pending_replay` : les revisionnages demandés et pas
/// encore accordés d'une Vibe.
async fn card_deliveries_pending_replay(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: ParCarte = parse(args)?;
    let sql = format!(
        "select coalesce(json_agg(d), '[]'::json) from public.card_deliveries d
          where d.card_id = $2 and d.replay_requested_at is not null and d.replay_granted_at is null
            and (d.recipient_id = $1 or {})",
        q::possede_carte("d.card_id", "$1::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(a.card_id).fetch_one(ctx.db()).await?)
}

/// `card_replay_requests_mine` : les revisionnages demandés sur MES Vibes,
/// chacun avec sa Vibe (`cards`).
async fn card_replay_requests_mine(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('cards', to_jsonb(c))), '[]'::jsonb) as "j!"
             from public.card_deliveries d join public.cards c on c.id = d.card_id
            where c.owner_id = $1 and d.replay_requested_at is not null and d.replay_granted_at is null"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

/// `card_delivery_mine` : ma livraison d'une Vibe, ou `null`.
async fn card_delivery_mine(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: ParCarte = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select to_json(d) as "j!" from public.card_deliveries d where d.card_id = $1 and d.recipient_id = $2"#,
        a.card_id,
        moi
    )
    .fetch_optional(ctx.db())
    .await?
    .unwrap_or(Value::Null))
}

/// `friend_share_defaults_list` : mes réglages d'envoi par ami.
async fn friend_share_defaults_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('friend_id', d.friend_id, 'saveable', d.saveable)), '[]'::json) as "j!"
             from public.friend_share_defaults d where d.owner_id = $1"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Defaut {
    owner_id: Uuid,
    friend_id: Uuid,
    saveable: bool,
    updated_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Defauts {
    rows: Vec<Defaut>,
}

/// `friend_share_defaults_upsert` : plusieurs réglages d'un coup.
async fn friend_share_defaults_upsert(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Defauts = parse(args)?;
    if a.rows.iter().any(|r| r.owner_id != moi) {
        return Err(NvError::refused("On ne règle que ses propres envois."));
    }
    for r in a.rows {
        sqlx::query!(
            "insert into public.friend_share_defaults (owner_id, friend_id, saveable, updated_at) values ($1, $2, $3, coalesce($4, now()))
             on conflict (owner_id, friend_id) do update set saveable = excluded.saveable, updated_at = excluded.updated_at",
            moi,
            r.friend_id,
            r.saveable,
            r.updated_at
        )
        .execute(ctx.db())
        .await?;
    }
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnAmi {
    friend_id: Uuid,
}

async fn friend_share_default_delete(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnAmi = parse(args)?;
    sqlx::query!("delete from public.friend_share_defaults where owner_id = $1 and friend_id = $2", moi, a.friend_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}
