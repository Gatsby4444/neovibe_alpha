//! Le noyau du serveur NeoVibe : ce que tous les domaines partagent.
//!
//! - [`error::NvError`] : chaque refus a un code et un message en français,
//!   le même que l'ancien gardien SQL (la preuve par comparaison le vérifie) ;
//! - [`actor::Actor`] : qui appelle (un compte connecté, ou personne) ;
//! - [`ctx::Ctx`] : ce qu'une opération reçoit — sa transaction, l'appelant,
//!   l'heure de la base, et ce qu'il faudra faire APRÈS la validation ;
//! - [`ops`] : le registre des guichets, un nom → une fonction.
pub mod actor;
pub mod args;
pub mod contrainte;
pub mod ctx;
pub mod error;
pub mod ops;

pub use actor::Actor;
pub use ctx::{AfterCommit, Ctx};
pub use error::{NvError, NvResult};
