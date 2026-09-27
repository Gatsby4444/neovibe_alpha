//! **L'ancre gommée** (ex-`private.gomme_ancre`) : une position publiée
//! n'est jamais exacte — elle est ramenée au centre d'une case de la grille
//! (`feed_rules.anchor_cell_m`, 100 m aujourd'hui).
//!
//! Le calcul se fait dans la base, avec ses fonctions (`round`, `cos`) :
//! l'ancien gardien et le nouveau donnent ainsi le même nombre au dernier
//! chiffre près.
use sqlx::PgConnection;

use nv_core::NvResult;

/// La case de la grille qui contient ce point.
pub async fn gommer(db: &mut PgConnection, lat: f64, lng: f64) -> NvResult<(Option<f64>, Option<f64>)> {
    let r = sqlx::query!(
        r#"with r as (select anchor_cell_m::double precision / 111320.0 as pas_lat from public.feed_rules where id),
                a as (select round($1 / r.pas_lat) * r.pas_lat as lat, r.pas_lat from r)
           select a.lat, round($2 / (a.pas_lat / greatest(cos(radians(a.lat)), 0.01)))
                         * (a.pas_lat / greatest(cos(radians(a.lat)), 0.01)) as lng
             from a"#,
        lat,
        lng
    )
    .fetch_optional(db)
    .await?;
    Ok(r.map(|r| (r.lat, r.lng)).unwrap_or((None, None)))
}
