//! Les questions d'accès partagées par plusieurs domaines.
//!
//! Chacune est la traduction d'une fonction de l'ancien gardien SQL (nommée
//! en tête de chaque fonction) ; chacune est écrite UNE fois ici et appelée
//! partout ailleurs.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// `private.a_bloque(qui, cible)` : `qui` a bloqué `cible`.
pub async fn a_bloque(db: &mut PgConnection, qui: Uuid, cible: Uuid) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.blocks
                           where blocker_id = $1 and blocked_id = $2) as "b!""#,
        qui,
        cible
    )
    .fetch_one(db)
    .await?)
}

/// `private.is_blocked(a, b)` : l'un des deux a bloqué l'autre.
pub async fn is_blocked(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.blocks
                           where (blocker_id = $1 and blocked_id = $2)
                              or (blocker_id = $2 and blocked_id = $1)) as "b!""#,
        a,
        b
    )
    .fetch_one(db)
    .await?)
}

/// `private.has_any_connection(a, b)` : un lien existe entre les deux,
/// quel que soit son statut.
pub async fn has_any_connection(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.connections
                           where user_low = least($1::uuid, $2::uuid)
                             and user_high = greatest($1::uuid, $2::uuid)) as "b!""#,
        a,
        b
    )
    .fetch_one(db)
    .await?)
}

/// `private.can_view_profile(viewer, target)` : le lecteur peut voir le
/// profil de la cible.
///
/// ⚠️ `a_bloque(target, viewer)` et non `is_blocked` : la cible s'est
/// retirée de la vue du lecteur ; l'inverse ne se déduit pas. Celui qu'on a
/// bloqué reste consultable (pour pouvoir le débloquer).
pub async fn can_view_profile(db: &mut PgConnection, viewer: Uuid, target: Uuid) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select $1::uuid = $2::uuid
             or (
               not exists (select 1 from public.blocks
                            where blocker_id = $2 and blocked_id = $1)
               and (
                 exists (select 1 from public.connections
                          where user_low = least($1::uuid, $2::uuid)
                            and user_high = greatest($1::uuid, $2::uuid))
                 or exists (select 1 from public.encounters e
                             where e.user_low = least($1::uuid, $2::uuid)
                               and e.user_high = greatest($1::uuid, $2::uuid))
                 or exists (select 1 from public.conversation_members m1
                              join public.conversation_members m2 using (conversation_id)
                             where m1.user_id = $1 and m2.user_id = $2)
                 or exists (select 1 from public.connection_requests
                             where (sender_id = $1 and receiver_id = $2)
                                or (sender_id = $2 and receiver_id = $1))
                 or exists (select 1 from public.recommendations
                             where (intermediary_id = $1 and (requester_id = $2 or target_id = $2))
                                or (requester_id = $1 and intermediary_id = $2)
                                or (target_id = $1 and intermediary_id = $2)
                                or (requester_id = $1 and target_id = $2 and status = 'accepted')
                                or (target_id = $1 and requester_id = $2
                                    and status in ('forwarded', 'accepted')))
                 or exists (select 1 from public.blocks
                             where blocker_id = $1 and blocked_id = $2)
               )
             ) as "b!""#,
        viewer,
        target
    )
    .fetch_one(db)
    .await?)
}
