//! **Le passage obligé de tout message.**
//!
//! Chaque message — texte, photo, vocal, Vibe, partage, demande de position
//! — s'écrit par [`ecrire`], et seulement par là. C'est la traduction du
//! déclencheur `enforce_message_rules` (qui voyait tous les chemins) : ce qui
//! était « là où tous passent » dans la base l'est maintenant dans le
//! programme. Aucun autre fichier n'écrit dans `messages`.
use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::{NvError, NvResult};

use crate::acces::{self, q, vrai, P};

/// Un message à écrire. Ce qui est `None` prend la valeur par défaut de la
/// base (identifiant tiré au hasard, type `text`, expiration à 24 h).
#[derive(Default)]
pub struct Nouveau<'a> {
    pub id: Option<Uuid>,
    pub conversation_id: Uuid,
    pub sender_id: Uuid,
    pub kind: Option<&'a str>,
    pub body: Option<&'a str>,
    pub media_path: Option<&'a str>,
    pub card_id: Option<Uuid>,
    pub content_id: Option<Uuid>,
    pub duration_ms: Option<i32>,
    pub expires_at: Option<DateTime<Utc>>,
}

/// Les règles d'écriture (ex-`enforce_message_rules`, dans le même ordre,
/// avec les mêmes messages), puis l'écriture ; rend la ligne écrite.
pub async fn ecrire(db: &mut PgConnection, m: Nouveau<'_>) -> NvResult<Value> {
    let (conv, qui) = (m.conversation_id, m.sender_id);
    let id = m.id.unwrap_or_else(Uuid::new_v4);
    let kind = m.kind.unwrap_or("text");
    if !acces::membre_conversation(db, conv, qui).await? {
        return Err(NvError::refused("Conversation introuvable"));
    }
    acces::refuser_si_suspendu(db, qui).await?;
    let ecrire = format!("({}) is distinct from false", q::peut_ecrire_conversation("$1::uuid", "$2::uuid"));
    if !vrai(db, &ecrire, &[P::U(conv), P::U(qui)]).await? {
        let soiree_finie = sqlx::query_scalar!(
            r#"select exists (select 1 from public.events e where e.conversation_id = $1 and e.closed_at is not null) as "b!""#,
            conv
        )
        .fetch_one(&mut *db)
        .await?;
        return Err(NvError::refused(if soiree_finie {
            "Cette soirée est terminée : son chat est fermé"
        } else {
            "Tu ne peux plus écrire dans cette conversation"
        }));
    }
    if kind == "location_request" {
        let vraie = sqlx::query_scalar!(
            r#"select exists (select 1 from public.location_requests r where r.message_id = $1 and r.requester_id = $2) as "b!""#,
            id,
            qui
        )
        .fetch_one(&mut *db)
        .await?;
        if !vraie {
            return Err(NvError::refused("Demande de position invalide"));
        }
    }
    let proximite = sqlx::query_scalar!(
        r#"select conversation_type::text as "t!" from public.conversations where id = $1"#,
        conv
    )
    .fetch_optional(&mut *db)
    .await?
    .is_some_and(|t| t == "proximity");
    if proximite {
        if kind != "text" {
            return Err(NvError::refused("Le canal de proximité est limité au texte"));
        }
        let r = sqlx::query!(
            r#"select exists (select 1 from public.messages where conversation_id = $1 and sender_id <> $2) as "repondu!",
                      (select count(*) from public.messages where conversation_id = $1 and sender_id = $2) as "miens!""#,
            conv,
            qui
        )
        .fetch_one(&mut *db)
        .await?;
        if !r.repondu && r.miens >= 3 {
            return Err(NvError::refused("Limite de 3 messages sans réponse atteinte"));
        }
    }
    if let Some(carte) = m.card_id {
        let a_moi = sqlx::query_scalar!(
            r#"select exists (select 1 from public.cards where id = $1 and owner_id = $2) as "b!""#,
            carte,
            qui
        )
        .fetch_one(&mut *db)
        .await?;
        if !a_moi {
            return Err(NvError::refused("Card invalide"));
        }
    }
    Ok(sqlx::query_scalar!(
        r#"insert into public.messages as m (id, conversation_id, sender_id, kind, body, media_path, card_id, content_id,
                                             duration_ms, expires_at)
           values ($1, $2, $3, $4::text::public.message_kind, $5, $6, $7, $8, $9, coalesce($10, now() + interval '24 hours'))
           returning to_json(m) as "j!""#,
        id,
        conv,
        qui,
        kind,
        m.body,
        m.media_path,
        m.card_id,
        m.content_id,
        m.duration_ms,
        m.expires_at
    )
    .fetch_one(db)
    .await?)
}
