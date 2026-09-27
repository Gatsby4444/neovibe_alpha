//! Les soirées (docs/serveur-rust.md, annexe A.7 ; docs/evenements.md) :
//! les créer, y entrer en y étant, les régler, les fermer ; les gens, les
//! points chauds, le récap ; la mémoire des rencontres.
//!
//! - [`regles`] : les questions propres aux soirées (présent ? peut
//!   inviter ? trop loin ?) ;
//! - [`cuisine`] : les écritures partagées (fermer, entrer dans un moment,
//!   oublier une affiche) ;
//! - [`guichet`] : les opérations ;
//! - [`balai`] : ce qui se fait seul, chaque minute et chaque nuit.
pub mod balai;
pub mod cuisine;
pub mod guichet;
pub mod regles;

pub use guichet::registry;
