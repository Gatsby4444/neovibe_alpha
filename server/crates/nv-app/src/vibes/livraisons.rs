//! **Le passage obligé de toute livraison de Vibe** (ex-déclencheur
//! `enforce_card_delivery_rules`, réparé le 2026-09-27 : voir
//! `20260927110100_la_vibe_jointe_a_une_demande.sql`).
//!
//! Une Vibe ne part qu'à un AMI — ou à la personne croisée à qui son auteur
//! vient de l'envoyer AVEC une demande d'ami en attente. Une Vibe « 1/1 »
//! n'a qu'un destinataire. Aucun autre fichier n'écrit dans
//! `card_deliveries`.
use serde_json::Value;
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::{NvError, NvResult};

use crate::acces;

/// Les règles d'une livraison (sans l'écrire).
pub async fn regles(db: &mut PgConnection, carte: Uuid, destinataire: Uuid) -> NvResult<()> {
    let c = sqlx::query!(r#"select owner_id, card_type::text as "card_type!" from public.cards where id = $1"#, carte)
        .fetch_optional(&mut *db)
        .await?;
    let Some(c) = c else { return Ok(()) };
    if c.owner_id != destinataire && !acces::sont_amis(db, c.owner_id, destinataire).await? {
        let demande_jointe = sqlx::query_scalar!(
            r#"select exists (select 1 from public.connection_requests r
                               where r.sender_id = $1 and r.receiver_id = $2 and r.card_id = $3
                                 and r.status = 'pending' and r.expires_at > now()) as "b!""#,
            c.owner_id,
            destinataire,
            carte
        )
        .fetch_one(&mut *db)
        .await?;
        if !demande_jointe {
            return Err(NvError::refused("Les Cards ne peuvent être envoyées qu'à des connexions"));
        }
    }
    if c.card_type == "one_of_one" {
        let deja = sqlx::query_scalar!(r#"select exists (select 1 from public.card_deliveries where card_id = $1) as "b!""#, carte)
            .fetch_one(&mut *db)
            .await?;
        if deja {
            return Err(NvError::refused("Une Card One of One ne peut avoir qu'un seul destinataire"));
        }
    }
    Ok(())
}

/// Écrit la livraison (les règles ont été vérifiées) ; `None` si elle
/// existait déjà et que le doublon est ignoré.
pub async fn inserer(db: &mut PgConnection, carte: Uuid, destinataire: Uuid, message: Option<Uuid>, ignorer_doublon: bool) -> NvResult<Option<Value>> {
    Ok(if ignorer_doublon {
        sqlx::query_scalar!(
            r#"insert into public.card_deliveries as d (card_id, recipient_id, message_id) values ($1, $2, $3)
               on conflict do nothing returning to_json(d) as "j!""#,
            carte,
            destinataire,
            message
        )
        .fetch_optional(db)
        .await?
    } else {
        Some(
            sqlx::query_scalar!(
                r#"insert into public.card_deliveries as d (card_id, recipient_id, message_id) values ($1, $2, $3)
                   returning to_json(d) as "j!""#,
                carte,
                destinataire,
                message
            )
            .fetch_one(db)
            .await?,
        )
    })
}

/// Les règles, puis l'écriture.
pub async fn livrer(db: &mut PgConnection, carte: Uuid, destinataire: Uuid, message: Option<Uuid>, ignorer_doublon: bool) -> NvResult<Option<Value>> {
    regles(db, carte, destinataire).await?;
    inserer(db, carte, destinataire, message, ignorer_doublon).await
}
