//! Comptes et profils (docs/serveur-rust.md, annexe A.1).
//!
//! La connexion elle-même (inscription, badge, renouvellement) vit dans
//! `nv-server` (le service commun du badge) ; ce domaine porte ce qui
//! concerne les profils.
pub mod cuisine;
pub mod gardien;
pub mod guichet;
