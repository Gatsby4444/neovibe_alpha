//! Les lectures et écritures des comptes et des profils.
use serde_json::Value;
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// Un profil porte déjà ce nom (sans tenir compte des majuscules).
pub async fn username_pris(db: &mut PgConnection, nom: &str) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.profiles
                           where lower(display_name) = lower($1)) as "b!""#,
        nom
    )
    .fetch_one(db)
    .await?)
}

/// Ma suspension, s'il y en a une (`[]` sinon).
pub async fn ma_suspension(db: &mut PgConnection, moi: Uuid) -> NvResult<Value> {
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!"
             from (select p.suspended_at, p.suspended_reason as reason
                     from public.profiles p
                    where p.id = $1 and p.suspended_at is not null) t"#,
        moi
    )
    .fetch_one(db)
    .await?)
}

/// Les chiffres d'un profil : amis, publications, Vibes de la semaine.
pub async fn chiffres_du_profil(db: &mut PgConnection, cible: Uuid) -> NvResult<Value> {
    Ok(sqlx::query_scalar!(
        r#"select json_build_array(json_build_object(
             'friends', (select count(*)::integer from public.connections
                          where (user_low = $1 or user_high = $1) and status = 'full'),
             'posts', (select count(*)::integer from public.library_items where owner_id = $1),
             'cards_week', (
               (select count(*) from public.cards c
                 where c.owner_id = $1
                   and c.created_at > now() - interval '7 days'
                   and exists (select 1 from public.card_deliveries d where d.card_id = c.id))
               + (select count(*) from public.contents ct
                   where ct.owner_id = $1
                     and ct.created_at > now() - interval '7 days'))::integer
           )) as "j!""#,
        cible
    )
    .fetch_one(db)
    .await?)
}
