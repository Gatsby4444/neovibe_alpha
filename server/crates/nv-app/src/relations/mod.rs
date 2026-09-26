//! Relations et proximité (docs/serveur-rust.md, annexe A.3) : le ping, les
//! croisements, les demandes d'ami, les recommandations, les blocages, les
//! saluts, les paliers d'amitié et la mémoire des rencontres.
//!
//! - `regles.rs` : les constantes et les petites règles pures ;
//! - `guichet.rs` : les opérations, pas à pas comme les anciennes fonctions ;
//! - `cuisine.rs` : les lectures et écritures ;
//! - `paliers.rs`, `rencontres.rs` : partagés avec les soirées.
pub mod cuisine;
pub mod guichet;
pub mod paliers;
pub mod regles;
pub mod rencontres;

/// Le balai du ping (ex-`purge_ping`, toutes les 5 minutes) : balises
/// éteintes, confirmations de plus d'une heure, paires et croisements hors
/// de leur fenêtre.
pub async fn balai_ping(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let sql = format!(
        "with a as (delete from public.ping_beacons where updated_at < now() - ({vie} * 2) returning 1),
              b as (delete from public.ping_confirmations where created_at < now() - interval '1 hour' returning 1),
              c as (delete from public.ping_pairs where last_seen_at < now() - {fp} returning 1),
              d as (delete from public.event_crossings where last_at < now() - {fe} returning 1)
         select (select count(*) from a) + (select count(*) from b) + (select count(*) from c) + (select count(*) from d)",
        vie = regles::VIE_BALISE,
        fp = crate::acces::q::fenetre("ping"),
        fe = crate::acces::q::fenetre("event"),
    );
    let n: i64 = sqlx::query_scalar(&sql).fetch_one(db).await?;
    Ok(format!("{n} ligne(s) retirée(s)"))
}

/// Le balai des vues Bluetooth (ex-`purge_sightings`, chaque heure) : plus
/// de 48 heures.
pub async fn balai_vues(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let n = sqlx::query!("delete from public.sightings where created_at < now() - interval '48 hours'")
        .execute(db)
        .await?
        .rows_affected();
    Ok(format!("{n} vue(s) retirée(s)"))
}
