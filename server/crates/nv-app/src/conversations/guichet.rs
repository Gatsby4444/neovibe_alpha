//! Les guichets des conversations.
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use super::messages::{self, Nouveau};
use crate::acces::{self, q, vrai, P};
use crate::comptes::cuisine::profil_vu;
use crate::direct::Table;

ops![
    create_group_conversation => create_group_conversation,
    get_or_create_direct_conversation => get_or_create_direct_conversation,
    get_or_create_proximity_conversation => get_or_create_proximity_conversation,
    hide_message => hide_message,
    send_voice_message => send_voice_message,
    open_voice_message => open_voice_message,
    conversations_list => conversations_list,
    conversation_get => conversation_get,
    conversation_update_title => conversation_update_title,
    conversation_member_add => conversation_member_add,
    conversation_member_remove => conversation_member_remove,
    message_send => message_send,
    message_last => message_last,
    message_reads_mark => message_reads_mark,
    conversation_participation_list => conversation_participation_list,
    categories_list => categories_list,
    category_create => category_create,
    category_delete => category_delete,
    category_members_list => category_members_list,
    category_member_add => category_member_add,
    category_member_remove => category_member_remove,
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Groupe {
    p_title: Option<String>,
    #[serde(default)]
    p_member_ids: Option<Vec<Uuid>>,
}

/// `create_group_conversation` : un groupe, avec ceux de mes AMIS que j'y
/// mets (les autres sont ignorés sans bruit).
async fn create_group_conversation(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Non authentifie"))?;
    let a: Groupe = parse(args)?;
    let titre = a.p_title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
    let id = sqlx::query_scalar!(
        "insert into public.conversations (conversation_type, title, created_by) values ('group', $1, $2) returning id",
        titre,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    sqlx::query!("insert into public.conversation_members (conversation_id, user_id) values ($1, $2)", id, moi)
        .execute(ctx.db())
        .await?;
    for membre in a.p_member_ids.unwrap_or_default() {
        if membre != moi && acces::sont_amis(ctx.db(), moi, membre).await? {
            sqlx::query!(
                "insert into public.conversation_members (conversation_id, user_id) values ($1, $2) on conflict do nothing",
                id,
                membre
            )
            .execute(ctx.db())
            .await?;
        }
    }
    Ok(json!(id))
}

/// Une conversation à deux, retrouvée par sa clé de paire ou créée.
async fn conversation_a_deux(ctx: &mut Ctx, moi: Uuid, pair: Uuid, type_: &str, prefixe: &str, indispo: &'static str) -> NvResult<Uuid> {
    let cle = format!("{prefixe}:{}:{}", moi.min(pair), moi.max(pair));
    sqlx::query!(
        "insert into public.conversations (conversation_type, pair_key, created_by)
         values ($1::text::public.conversation_type, $2, $3) on conflict (pair_key) do nothing",
        type_,
        cle,
        moi
    )
    .execute(ctx.db())
    .await?;
    let id = sqlx::query_scalar!(
        "select id from public.conversations where pair_key = $1 and conversation_type = $2::text::public.conversation_type",
        cle,
        type_
    )
    .fetch_optional(ctx.db())
    .await?
    .ok_or_else(|| NvError::refused(indispo))?;
    sqlx::query!(
        "insert into public.conversation_members (conversation_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing",
        id,
        moi,
        pair
    )
    .execute(ctx.db())
    .await?;
    Ok(id)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Pair {
    peer: Uuid,
}

/// **La conversation directe** de deux amis, retrouvée ou créée — réservée
/// aux amis. (Aussi le chemin de la demande de position : un seul endroit
/// décide qui peut s'écrire en privé.)
pub async fn conversation_directe(ctx: &mut Ctx, moi: Option<Uuid>, pair: Uuid) -> NvResult<Uuid> {
    let moi = match moi {
        Some(m) if acces::sont_amis(ctx.db(), m, pair).await? => m,
        _ => return Err(NvError::refused("Messagerie directe réservée aux connexions établies")),
    };
    conversation_a_deux(ctx, moi, pair, "direct", "direct", "Conversation directe indisponible").await
}

/// `get_or_create_direct_conversation` : réservée aux amis.
async fn get_or_create_direct_conversation(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Pair = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    Ok(json!(conversation_directe(ctx, moi, a.peer).await?))
}

/// `get_or_create_proximity_conversation` : le canal de proximité, ouvert
/// 3 minutes après un ping mutuel, entre deux personnes qui ne sont PAS amies.
async fn get_or_create_proximity_conversation(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Pair = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    if let Some(m) = moi {
        if acces::sont_amis(ctx.db(), m, a.peer).await? {
            return Err(NvError::refused("Déjà connectés : utilisez la messagerie directe"));
        }
    }
    let recent = match moi {
        None => false,
        Some(m) => sqlx::query_scalar!(
            r#"select exists (select 1 from public.ping_pairs pp
                               where ((pp.user_low = $1 and pp.user_high = $2) or (pp.user_low = $2 and pp.user_high = $1))
                                 and pp.last_seen_at > now() - interval '3 minutes') as "b!""#,
            m,
            a.peer
        )
        .fetch_one(ctx.db())
        .await?,
    };
    let Some(moi) = moi.filter(|_| recent) else { return Err(NvError::refused("Proximité non constatée")) };
    Ok(json!(conversation_a_deux(ctx, moi, a.peer, "proximity", "prox", "Canal de proximité indisponible").await?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnMessage {
    p_message_id: Uuid,
}

/// `hide_message` : masquer un message pour moi seul.
async fn hide_message(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: UnMessage = parse(args)?;
    let moi = ctx.actor.maybe_uid();
    let visible = match moi {
        None => false,
        Some(m) => vrai(
            ctx.db(),
            &format!("exists (select 1 from public.messages g where g.id = $1::uuid and {})", q::membre_conversation("g.conversation_id", "$2::uuid")),
            &[P::U(a.p_message_id), P::U(m)],
        )
        .await?,
    };
    let Some(moi) = moi.filter(|_| visible) else { return Err(NvError::refused("Message introuvable")) };
    sqlx::query!(
        "insert into public.hidden_messages (user_id, message_id) values ($1, $2) on conflict do nothing",
        moi,
        a.p_message_id
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Vocal {
    p_conversation_id: Uuid,
    p_media_path: Option<String>,
    p_duration_ms: Option<i32>,
    p_media_key: Option<String>,
}

/// `send_voice_message` : un vocal (2 minutes au plus), dans un DM, un
/// groupe ou une soirée privée ; sa clé de déchiffrement est déposée à part.
async fn send_voice_message(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Non authentifié"))?;
    let a: Vocal = parse(args)?;
    let (Some(chemin), Some(cle)) = (a.p_media_path.as_deref(), a.p_media_key.as_deref().filter(|k| !k.is_empty())) else {
        return Err(NvError::refused("Vocal incomplet"));
    };
    let duree = a.p_duration_ms.filter(|d| *d > 0 && *d <= 120_000).ok_or_else(|| NvError::refused("Durée de vocal hors bornes"))?;
    if chemin.split('/').next() != Some(moi.to_string().as_str()) {
        return Err(NvError::refused("Chemin de média invalide"));
    }
    let type_ = sqlx::query_scalar!(r#"select conversation_type::text as "t!" from public.conversations where id = $1"#, a.p_conversation_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Conversation introuvable"))?;
    if type_ == "event" {
        let privee = sqlx::query_scalar!(
            r#"select exists (select 1 from public.events e where e.conversation_id = $1 and e.kind = 'private') as "b!""#,
            a.p_conversation_id
        )
        .fetch_one(ctx.db())
        .await?;
        if !privee {
            return Err(NvError::refused("Les vocaux ne s'envoient pas dans un événement d'établissement"));
        }
    } else if type_ != "direct" && type_ != "group" {
        return Err(NvError::refused("Les vocaux ne s'envoient que dans un DM ou un groupe"));
    }
    if !acces::membre_conversation(ctx.db(), a.p_conversation_id, moi).await? {
        return Err(NvError::refused("Conversation introuvable"));
    }
    let ecrire = format!("({}) is distinct from false", q::peut_ecrire_conversation("$1::uuid", "$2::uuid"));
    if !vrai(ctx.db(), &ecrire, &[P::U(a.p_conversation_id), P::U(moi)]).await? {
        return Err(NvError::refused("Vous ne pouvez pas écrire dans cette conversation"));
    }
    let ligne = messages::ecrire(
        ctx.db(),
        Nouveau {
            conversation_id: a.p_conversation_id,
            sender_id: moi,
            kind: Some("voice"),
            media_path: Some(chemin),
            duration_ms: Some(duree),
            ..Default::default()
        },
    )
    .await?;
    let id = ligne.get("id").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok()).ok_or_else(|| NvError::Internal("message sans id".into()))?;
    sqlx::query!("insert into public.message_media_keys (message_id, media_key) values ($1, $2)", id, cle)
        .execute(ctx.db())
        .await?;
    Ok(json!(id))
}

/// `open_voice_message` : la clé d'un vocal que j'ai le droit d'écouter.
async fn open_voice_message(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid().map_err(|_| NvError::refused("Non authentifié"))?;
    let a: UnMessage = parse(args)?;
    let ok = sqlx::query_scalar!(
        r#"select exists (select 1 from public.messages m
                            join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = $2
                           where m.id = $1 and m.kind = 'voice' and m.expires_at > now() and m.created_at >= cm.joined_at) as "b!""#,
        a.p_message_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if !ok {
        return Err(NvError::refused("Vocal introuvable"));
    }
    let cle = sqlx::query_scalar!("select media_key from public.message_media_keys where message_id = $1", a.p_message_id)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Vocal indisponible : sa clé n'a jamais été déposée"))?;
    Ok(json!(cle))
}

// ─── Ce que l'app faisait directement sur les tables ───────────────────────

/// La conversation (colonnes) et ses membres, chacun avec son profil (ou
/// `null` s'il n'est pas visible) — la forme de l'ancien
/// `select('*, members:conversation_members(profiles(*))')`.
fn requete_conversations(filtre: &str) -> String {
    format!(
        "select coalesce(json_agg(t order by t.created_at desc), '[]'::json) from (
           select c.*, (select coalesce(json_agg(json_build_object('profiles',
                          (select {vu} from public.profiles p where p.id = cm.user_id and {vis}))
                          order by cm.joined_at, cm.user_id), '[]'::json)
                          from public.conversation_members cm where cm.conversation_id = c.id) as members
             from public.conversations c where {membre} and {filtre}) t",
        vu = profil_vu("p", "$1::uuid"),
        vis = q::peut_voir_profil("$1::uuid", "p.id"),
        membre = q::membre_conversation("c.id", "$1::uuid"),
    )
}

/// `conversations_list` : mes conversations, les plus récentes d'abord.
async fn conversations_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    let sql = requete_conversations("$2::uuid is null");
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(None::<Uuid>).fetch_one(ctx.db()).await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneConversation {
    id: Uuid,
}

/// `conversation_get` : une conversation dont je suis membre.
async fn conversation_get(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UneConversation = parse(args)?;
    let sql = requete_conversations("c.id = $2::uuid");
    let v = sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(a.id).fetch_one(ctx.db()).await?;
    v.as_array().and_then(|l| l.first()).cloned().ok_or_else(|| NvError::refused("Conversation introuvable"))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Titre {
    id: Uuid,
    title: Option<String>,
}

/// `conversation_update_title` : renommer un groupe dont je suis membre.
async fn conversation_update_title(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Titre = parse(args)?;
    let sql = format!(
        "update public.conversations c set title = $3 where c.id = $2 and c.conversation_type = 'group' and {}",
        q::membre_conversation("c.id", "$1::uuid")
    );
    sqlx::query(&sql).bind(moi).bind(a.id).bind(a.title).execute(ctx.db()).await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Membre {
    conversation_id: Uuid,
    user_id: Uuid,
}

/// `conversation_member_add` : dans un GROUPE — soit je m'ajoute à celui que
/// j'ai créé, soit j'en suis membre et j'ajoute un AMI.
async fn conversation_member_add(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Membre = parse(args)?;
    let regle = format!(
        "exists (select 1 from public.conversations gc where gc.id = $1::uuid and gc.conversation_type = 'group' and \
           (($2::uuid = $3::uuid and gc.created_by = $3::uuid) or ({membre} and {amis})))",
        membre = q::membre_conversation("$1::uuid", "$3::uuid"),
        amis = q::sont_amis("$3::uuid", "$2::uuid"),
    );
    if !vrai(ctx.db(), &regle, &[P::U(a.conversation_id), P::U(a.user_id), P::U(moi)]).await? {
        return Err(NvError::refused("Ajout refusé : seulement un ami, dans un groupe dont tu es membre."));
    }
    sqlx::query!("insert into public.conversation_members (conversation_id, user_id) values ($1, $2)", a.conversation_id, a.user_id)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

/// `conversation_member_remove` : quitter, ou retirer quelqu'un d'un groupe
/// que j'ai créé.
async fn conversation_member_remove(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Membre = parse(args)?;
    sqlx::query!(
        "delete from public.conversation_members cm where cm.conversation_id = $1 and cm.user_id = $2
            and (cm.user_id = $3 or exists (select 1 from public.conversations c where c.id = cm.conversation_id
                                              and c.conversation_type = 'group' and c.created_by = $3))",
        a.conversation_id,
        a.user_id,
        moi
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envoi {
    conversation_id: Uuid,
    sender_id: Uuid,
    #[serde(default)]
    kind: Option<String>,
    body: Option<String>,
    media_path: Option<String>,
    card_id: Option<Uuid>,
}

/// `message_send` : un message écrit par l'app (texte, photo, vidéo, Vibe)
/// — par le passage obligé.
async fn message_send(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Envoi = parse(args)?;
    if a.sender_id != moi {
        return Err(NvError::refused("On n'écrit qu'en son propre nom."));
    }
    let kind = a.kind.as_deref();
    // ⚠️ Écart voulu : un vocal, un partage de contenu ou un ajout en
    // bibliothèque ont leur propre porte (et leurs propres règles : la clé
    // du vocal, le droit de partager ce contenu). L'ancien guichet laissait
    // les écrire directement dans la table, sans ces règles.
    if matches!(kind, Some("voice" | "content_share" | "library_add")) {
        return Err(NvError::refused("Ce type de message passe par sa propre opération."));
    }
    messages::ecrire(
        ctx.db(),
        Nouveau {
            conversation_id: a.conversation_id,
            sender_id: moi,
            kind,
            body: a.body.as_deref(),
            media_path: a.media_path.as_deref(),
            card_id: a.card_id,
            ..Default::default()
        },
    )
    .await
}

/// `message_last` : le dernier message visible d'une conversation.
async fn message_last(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Dernier {
        conversation_id: Uuid,
    }
    let a: Dernier = parse(args)?;
    let sql = format!(
        "select to_json(r) from public.messages r where r.conversation_id = $2 and {} order by r.created_at desc limit 1",
        Table::Messages.visible("r", "$1::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(a.conversation_id).fetch_optional(ctx.db()).await?.unwrap_or(Value::Null))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Lus {
    message_ids: Vec<Uuid>,
}

/// `message_reads_mark` : les messages des AUTRES que j'ai lus.
async fn message_reads_mark(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Lus = parse(args)?;
    let regle = format!(
        "exists (select 1 from public.messages mr where mr.id = $1::uuid and mr.sender_id <> $2::uuid and {})",
        q::membre_conversation("mr.conversation_id", "$2::uuid")
    );
    for id in &a.message_ids {
        if !vrai(ctx.db(), &regle, &[P::U(*id), P::U(moi)]).await? {
            return Err(NvError::refused("Lecture refusée."));
        }
    }
    sqlx::query!(
        "insert into public.message_reads (message_id, user_id) select unnest($1::uuid[]), $2 on conflict do nothing",
        &a.message_ids,
        moi
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

/// `conversation_participation_list` : quand j'ai écrit pour la dernière
/// fois dans chaque conversation.
async fn conversation_participation_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('conversation_id', p.conversation_id, 'last_at', p.last_at)), '[]'::json) as "j!"
             from public.conversation_participation p where p.user_id = $1"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

// ─── Mes catégories de conversations ────────────────────────────────────────

async fn categories_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(c order by c.created_at), '[]'::json) as "j!" from public.conversation_categories c where c.owner_id = $1"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Categorie {
    owner_id: Uuid,
    name: String,
}

async fn category_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Categorie = parse(args)?;
    if a.owner_id != moi {
        return Err(NvError::refused("On ne crée que ses propres catégories."));
    }
    sqlx::query!("insert into public.conversation_categories (owner_id, name) values ($1, $2)", moi, a.name)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

async fn category_delete(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UneConversation = parse(args)?;
    sqlx::query!("delete from public.conversation_categories where id = $1 and owner_id = $2", a.id, moi)
        .execute(ctx.db())
        .await?;
    Ok(Value::Null)
}

async fn category_members_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(json_build_object('category_id', m.category_id, 'conversation_id', m.conversation_id)), '[]'::json) as "j!"
             from public.conversation_category_members m
            where exists (select 1 from public.conversation_categories cc where cc.id = m.category_id and cc.owner_id = $1)"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rangement {
    category_id: Uuid,
    conversation_id: Uuid,
}

/// `category_member_add` : ranger une conversation dont je suis membre dans
/// une de MES catégories.
///
/// ⚠️ Écart voulu : ranger deux fois ne fait rien (l'ancien guichet
/// répondait par une erreur de politique sur le doublon).
async fn category_member_add(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Rangement = parse(args)?;
    let a_moi = sqlx::query_scalar!(
        r#"select exists (select 1 from public.conversation_categories cc where cc.id = $1 and cc.owner_id = $2) as "b!""#,
        a.category_id,
        moi
    )
    .fetch_one(ctx.db())
    .await?;
    if !a_moi || !acces::membre_conversation(ctx.db(), a.conversation_id, moi).await? {
        return Err(NvError::refused("Rangement refusé."));
    }
    sqlx::query!(
        "insert into public.conversation_category_members (category_id, conversation_id) values ($1, $2) on conflict do nothing",
        a.category_id,
        a.conversation_id
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}

async fn category_member_remove(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Rangement = parse(args)?;
    sqlx::query!(
        "delete from public.conversation_category_members m where m.category_id = $1 and m.conversation_id = $2
            and exists (select 1 from public.conversation_categories cc where cc.id = m.category_id and cc.owner_id = $3)",
        a.category_id,
        a.conversation_id,
        moi
    )
    .execute(ctx.db())
    .await?;
    Ok(Value::Null)
}
