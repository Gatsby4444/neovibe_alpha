//! Les domaines de NeoVibe : leurs guichets, leurs règles, leur cuisine.
//!
//! Chaque domaine range trois rôles séparés (docs/serveur-rust.md §2) :
//! - le **guichet** (`guichet.rs`) : lit la demande, appelle le gardien,
//!   renvoie la réponse — il ne décide rien ;
//! - le **gardien** (`gardien.rs`) : les règles du produit ;
//! - la **cuisine** (`cuisine.rs`) : les lectures et écritures en base — elle
//!   ne décide rien.
//!
//! [`acces`] regroupe les questions d'accès que plusieurs domaines posent
//! (« sont-ils amis ? », « l'un a-t-il bloqué l'autre ? ») : chacune est
//! écrite une seule fois.
pub mod acces;
pub mod carte;
pub mod comptes;
pub mod conversations;
pub mod direct;
pub mod fichiers;
pub mod relations;

use nv_core::ops::Op;

/// Toutes les opérations, tous domaines confondus.
pub fn registry() -> Vec<Op> {
    let mut ops = Vec::new();
    ops.extend(comptes::guichet::registry());
    ops.extend(fichiers::guichet::registry());
    ops.extend(direct::registry());
    ops.extend(relations::guichet::registry());
    ops.extend(conversations::guichet::registry());
    ops
}
