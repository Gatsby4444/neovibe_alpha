//! La carte (docs/serveur-rust.md, annexe A.8).
pub mod ancre;
pub mod autour;
pub mod guichet;
pub mod positions;

pub use guichet::registry;

/// Le balai des positions (ex-`neovibe_purge_friend_locations`, chaque heure
/// à :29) : une position plus vieille que `friend_position_max_age` s'efface.
pub async fn balai_positions(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let n = sqlx::query!(
        "delete from public.friend_locations where at < now() - (select friend_position_max_age from public.map_rules)"
    )
    .execute(db)
    .await?
    .rows_affected();
    Ok(format!("{n} position(s) effacée(s)"))
}

/// Le balai des demandes de position (ex-`neovibe_purge_location_requests`,
/// chaque heure à :37) : les positions données expirées, les demandes de
/// plus de deux jours.
pub async fn balai_demandes(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let r = sqlx::query!("delete from public.location_reveals where expires_at < now()").execute(&mut *db).await?.rows_affected();
    let d = sqlx::query!("delete from public.location_requests where created_at < now() - interval '2 days'")
        .execute(db)
        .await?
        .rows_affected();
    Ok(format!("{r} position(s) donnée(s) et {d} demande(s) effacée(s)"))
}
