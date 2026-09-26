//! Conversations (docs/serveur-rust.md, annexe A.4) : les messages, les
//! vocaux, les groupes, les canaux de proximité, les catégories.
//!
//! [`messages`] est le passage obligé de TOUT message (ex-déclencheur
//! `enforce_message_rules`).
pub mod guichet;
pub mod messages;

/// Le balai général (ex-`neovibe_purge`, toutes les 5 minutes) : messages
/// expirés, demandes et recommandations périmées, croisements de plus de
/// 24 h, contenus des stories expirées — dans UNE transaction, comme avant.
pub async fn balai_general(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let messages = sqlx::query!("delete from public.messages where expires_at < now()").execute(&mut *db).await?.rows_affected();
    sqlx::query!("update public.connection_requests set status = 'expired' where status = 'pending' and expires_at < now()")
        .execute(&mut *db)
        .await?;
    sqlx::query!(
        "update public.recommendations set status = 'expired' where status in ('requested', 'forwarded') and expires_at < now()"
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!("delete from public.encounters where last_seen_at < now() - interval '24 hours'").execute(&mut *db).await?;
    let stories = sqlx::query!(
        "delete from public.contents c where c.context = 'story'
            and exists (select 1 from public.stories s where s.id = c.id and s.expires_at < now())"
    )
    .execute(db)
    .await?
    .rows_affected();
    Ok(format!("{messages} message(s) et {stories} story(s) expirés"))
}

/// Le balai des canaux de proximité VIDES (ex-`purge_empty_proximity_conversations`,
/// toutes les 5 minutes) : plus de 5 minutes, sans message ni partage.
pub async fn balai_canaux(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let n = sqlx::query!(
        "delete from public.conversations c where c.conversation_type = 'proximity'
            and c.created_at < now() - interval '5 minutes'
            and not exists (select 1 from public.messages m where m.conversation_id = c.id)
            and not exists (select 1 from public.content_grants g where g.conversation_id = c.id)"
    )
    .execute(db)
    .await?
    .rows_affected();
    Ok(format!("{n} canal(aux) vide(s) retiré(s)"))
}
