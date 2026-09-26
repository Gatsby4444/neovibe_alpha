//! Qui appelle.
use uuid::Uuid;

use crate::error::{NvError, NvResult};

/// L'appelant d'une opération : un compte connecté, ou personne.
///
/// Le badge a été vérifié AVANT d'arriver ici (par le guichet HTTP, ou par
/// la preuve qui joue un compte) : un `Actor` ne se fabrique jamais à
/// partir de ce que l'app affirme.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Actor {
    /// Personne n'est connecté.
    Anonymous,
    /// Un compte connecté.
    User(Uuid),
}

impl Actor {
    /// L'identifiant du compte, ou un refus « connecte-toi ».
    pub fn uid(&self) -> NvResult<Uuid> {
        match self {
            Actor::User(id) => Ok(*id),
            Actor::Anonymous => Err(NvError::Unauthenticated),
        }
    }

    /// L'identifiant s'il y en a un.
    pub fn maybe_uid(&self) -> Option<Uuid> {
        match self {
            Actor::User(id) => Some(*id),
            Actor::Anonymous => None,
        }
    }
}
