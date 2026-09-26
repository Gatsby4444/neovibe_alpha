//! Les questions d'accès partagées par plusieurs domaines.
//!
//! Chacune est la traduction d'une fonction de l'ancien gardien SQL (nommée
//! en tête de chaque fonction) ; chacune est écrite UNE fois ici et appelée
//! partout ailleurs.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// **La suspension** (ex-`private.assert_not_suspended` et déclencheur
/// `refuse_si_suspendu`) : un compte suspendu ne crée plus rien — ni
/// contenu, ni soirée, ni relation. Chaque porte qui crée appelle CETTE
/// vérification ; elle n'est écrite qu'ici.
pub async fn refuser_si_suspendu(db: &mut PgConnection, moi: Uuid) -> NvResult<()> {
    let suspendu = sqlx::query_scalar!(
        r#"select exists (select 1 from public.profiles
                           where id = $1 and suspended_at is not null) as "b!""#,
        moi
    )
    .fetch_one(db)
    .await?;
    if suspendu {
        return Err(nv_core::NvError::refused("Ton compte est suspendu"));
    }
    Ok(())
}

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
pub async fn can_view_profile(db: &mut PgConnection, viewer: Uuid, target: Uuid) -> NvResult<bool> {
    Ok(profils_visibles(db, viewer, &[target]).await?.contains(&target))
}

/// Parmi `cibles`, les profils que `viewer` peut voir — la même règle que
/// [`can_view_profile`], posée une seule fois et pour une liste entière.
///
/// ⚠️ `a_bloque(cible, lecteur)` et non `is_blocked` : la cible s'est
/// retirée de la vue du lecteur ; l'inverse ne se déduit pas. Celui qu'on a
/// bloqué reste consultable (pour pouvoir le débloquer).
pub async fn profils_visibles(db: &mut PgConnection, viewer: Uuid, cibles: &[Uuid]) -> NvResult<Vec<Uuid>> {
    Ok(sqlx::query_scalar!(
        r#"select t.id as "id!"
             from unnest($2::uuid[]) as t(id)
            where $1::uuid = t.id
               or (
                 not exists (select 1 from public.blocks
                              where blocker_id = t.id and blocked_id = $1)
                 and (
                   exists (select 1 from public.connections
                            where user_low = least($1::uuid, t.id)
                              and user_high = greatest($1::uuid, t.id))
                   or exists (select 1 from public.encounters e
                               where e.user_low = least($1::uuid, t.id)
                                 and e.user_high = greatest($1::uuid, t.id))
                   or exists (select 1 from public.conversation_members m1
                                join public.conversation_members m2 using (conversation_id)
                               where m1.user_id = $1 and m2.user_id = t.id)
                   or exists (select 1 from public.connection_requests
                               where (sender_id = $1 and receiver_id = t.id)
                                  or (sender_id = t.id and receiver_id = $1))
                   or exists (select 1 from public.recommendations
                               where (intermediary_id = $1 and (requester_id = t.id or target_id = t.id))
                                  or (requester_id = $1 and intermediary_id = t.id)
                                  or (target_id = $1 and intermediary_id = t.id)
                                  or (requester_id = $1 and target_id = t.id and status = 'accepted')
                                  or (target_id = $1 and requester_id = t.id
                                      and status in ('forwarded', 'accepted')))
                   or exists (select 1 from public.blocks
                               where blocker_id = $1 and blocked_id = t.id)
                 )
               )"#,
        viewer,
        cibles
    )
    .fetch_all(db)
    .await?)
}
