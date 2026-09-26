//! Traduire une protection de la base (contrainte) en refus lisible.
//!
//! La base garde ses protections de fond — unicité, formes, liens (« les
//! fondations de la maison », docs/serveur-rust.md). Quand l'une d'elles
//! refuse une écriture, l'app doit recevoir une phrase, pas le nom technique
//! d'un index.
use crate::error::NvError;

/// Si `e` est la violation d'une contrainte nommée dans `messages`, renvoie
/// le refus correspondant ; sinon, l'erreur telle quelle.
pub fn traduire(e: sqlx::Error, messages: &[(&str, &str)]) -> NvError {
    if let sqlx::Error::Database(d) = &e {
        if let Some(nom) = d.constraint() {
            if let Some((_, m)) = messages.iter().find(|(c, _)| *c == nom) {
                return NvError::refused(*m);
            }
        }
    }
    NvError::Db(e)
}
