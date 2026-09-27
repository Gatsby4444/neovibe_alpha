//! Modération et administration (docs/serveur-rust.md, annexe A.9).
//!
//! - [`signalements`] : signaler (et sceller la preuve, [`preuves`]) ;
//! - [`admin`] : les gestes des administrateurs, tous journalisés.
pub mod admin;
pub mod preuves;
pub mod signalements;

use nv_core::ops::Op;

/// Les opérations du domaine.
pub fn registry() -> Vec<Op> {
    let mut ops = signalements::registry();
    ops.extend(admin::registry());
    ops
}
