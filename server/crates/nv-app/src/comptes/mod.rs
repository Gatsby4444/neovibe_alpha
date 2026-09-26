//! Comptes et profils (docs/serveur-rust.md, annexe A.1).
//!
//! - [`badge`] : le jeton signé qui prouve qui appelle ;
//! - [`connexion`] : inscription, connexion, renouvellement, déconnexion
//!   (appelés par les routes `/v1/auth/…` de `nv-server`) ;
//! - le reste : les profils.
pub mod badge;
pub mod connexion;
pub mod cuisine;
pub mod gardien;
pub mod guichet;
