//! **La position des amis** — ex-`private.record_location`.
//!
//! Déposée seulement si le compte PARTAGE sa position, et au plus toutes les
//! 10 secondes quand la carte est ouverte (`map_rules.friend_live_every`),
//! toutes les 30 minutes sinon (`friend_background_every`) : on ne surcharge
//! ni les téléphones ni le serveur (Jay, 2026-09-26).
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// Dépose la position de `compte` si les règles le permettent ; rend vrai si
/// elle a été déposée.
pub async fn enregistrer(db: &mut PgConnection, compte: Uuid, lat: f64, lon: f64, acc: Option<f64>, en_direct: bool) -> NvResult<bool> {
    let partage = sqlx::query_scalar!(
        r#"select exists (select 1 from public.location_sharing where user_id = $1 and sharing) as "b!""#,
        compte
    )
    .fetch_one(&mut *db)
    .await?;
    if !partage || !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
        return Ok(false);
    }
    let trop_tot = sqlx::query_scalar!(
        r#"select coalesce(now() - f.at < case when $2 then r.friend_live_every else r.friend_background_every end, false) as "b!"
             from public.map_rules r left join public.friend_locations f on f.user_id = $1"#,
        compte,
        en_direct
    )
    .fetch_optional(&mut *db)
    .await?
    .unwrap_or(false);
    if trop_tot {
        return Ok(false);
    }
    sqlx::query!(
        "insert into public.friend_locations (user_id, lat, lon, acc, at)
         values ($1, $2, $3, greatest(0, coalesce($4::float8, 0)), now())
         on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, at = now()",
        compte,
        lat,
        lon,
        acc
    )
    .execute(db)
    .await?;
    Ok(true)
}
