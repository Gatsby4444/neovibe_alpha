//! Vibes et contenus (docs/serveur-rust.md, annexe A.6).
//!
//! - [`cartes`] : les Vibes ENVOYÉES (`cards`) — clé, visionnages, replays ;
//! - [`livraisons`] : le passage obligé de toute livraison de Vibe ;
//! - [`contenus`] : ce qui est commun aux stories et aux publications — clé,
//!   vues, likes, partage, retrait, lieu de prise ;
//! - [`drop`] : le Drop d'une conversation (`library_vibes`) ;
//! - [`publication`] : publier (story, bibliothèque) et relire.
pub mod cartes;
pub mod contenus;
pub mod drop;
pub mod livraisons;
pub mod publication;

use nv_core::ops::Op;

/// Les opérations du domaine.
pub fn registry() -> Vec<Op> {
    let mut ops = cartes::registry();
    ops.extend(contenus::registry());
    ops.extend(drop::registry());
    ops.extend(publication::registry());
    ops
}

/// Une valeur d'énumération (`card_type`, `library_kind`…) vérifiée par la
/// base, comme à l'appel d'une fonction SQL : une valeur inconnue est
/// refusée avant toute règle. `type_` est toujours un nom écrit dans le
/// code, jamais une valeur venue de l'app.
pub async fn enumeration(db: &mut sqlx::PgConnection, type_: &str, v: Option<&str>) -> nv_core::NvResult<Option<String>> {
    let Some(v) = v else { return Ok(None) };
    let sql = format!("select $1::text::public.{type_}::text");
    Ok(Some(sqlx::query_scalar::<_, String>(&sql).bind(v).fetch_one(db).await?))
}

/// Le balai du Drop (ex-`purge_expired_library_vibes`, toutes les
/// 5 minutes) : une Vibe éphémère disparaît 24 h après son reveal.
pub async fn balai_drop(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let n = sqlx::query!("delete from public.library_vibes where ephemeral and now() > reveal_at + interval '24 hours'")
        .execute(db)
        .await?
        .rows_affected();
    Ok(format!("{n} Vibe(s) éphémère(s) retirée(s) du Drop"))
}

/// Le balai des annonces de disparition (ex-`purge_removals`, toutes les
/// heures) : une annonce sert 24 h, le temps que chaque écran l'ait lue.
pub async fn balai_retraits(db: &mut sqlx::PgConnection) -> nv_core::NvResult<String> {
    let n = sqlx::query!("delete from public.removals where created_at < now() - interval '24 hours'")
        .execute(db)
        .await?
        .rows_affected();
    Ok(format!("{n} annonce(s) de disparition effacée(s)"))
}
