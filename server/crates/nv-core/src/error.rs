//! Les erreurs du serveur.
//!
//! Deux familles, qui ne se mélangent pas :
//! - les **refus** : une règle du produit dit non. Le message est destiné à
//!   l'utilisateur, en français, et reprend mot pour mot celui de l'ancien
//!   gardien SQL (`raise exception '…'`) ;
//! - les **pannes** : la base ou le programme a un problème. Le détail va au
//!   journal, l'utilisateur reçoit un message générique.
use serde_json::json;

pub type NvResult<T> = Result<T, NvError>;

#[derive(Debug, thiserror::Error)]
pub enum NvError {
    /// Une règle du produit refuse (l'équivalent d'un `raise exception`).
    #[error("{0}")]
    Refused(String),
    /// Personne n'est connecté, ou le badge n'est plus valable.
    #[error("Connecte-toi pour continuer.")]
    Unauthenticated,
    /// Le badge est valable mais l'opération ne lui est pas ouverte.
    #[error("Tu n'as pas accès à cette opération.")]
    Forbidden,
    /// Aucun guichet ne porte ce nom.
    #[error("Opération inconnue : {0}")]
    UnknownOp(String),
    /// La demande est mal formée (argument manquant, inconnu, mauvais type).
    #[error("Demande invalide : {0}")]
    BadArgs(String),
    /// La base a répondu par une erreur.
    #[error("base : {0}")]
    Db(#[from] sqlx::Error),
    /// Une panne interne.
    #[error("interne : {0}")]
    Internal(String),
}

impl NvError {
    /// Un refus, avec le message à montrer.
    pub fn refused(message: impl Into<String>) -> Self {
        NvError::Refused(message.into())
    }

    /// L'état SQL d'une erreur de la base (`23505`…), s'il y en a un.
    pub fn sqlstate(&self) -> Option<String> {
        match self {
            NvError::Db(sqlx::Error::Database(d)) => d.code().map(|c| c.to_string()),
            _ => None,
        }
    }

    /// Une protection de fond de la base a refusé l'écriture (classe `23` :
    /// doublon, colonne obligatoire, forme) ou la donnée (classe `22` :
    /// valeur illisible). C'est un REFUS, pas une panne.
    pub fn refus_de_la_base(&self) -> bool {
        self.sqlstate().is_some_and(|c| c.starts_with("23") || c.starts_with("22"))
    }

    /// Le code HTTP de la réponse.
    pub fn status(&self) -> u16 {
        if self.refus_de_la_base() {
            return 400;
        }
        match self {
            NvError::Refused(_) | NvError::BadArgs(_) => 400,
            NvError::Unauthenticated => 401,
            NvError::Forbidden => 403,
            NvError::UnknownOp(_) => 404,
            NvError::Db(_) | NvError::Internal(_) => 500,
        }
    }

    /// Le code court, stable, que l'app peut lire.
    pub fn code(&self) -> &'static str {
        match self {
            NvError::Refused(_) => "refused",
            NvError::Unauthenticated => "unauthenticated",
            NvError::Forbidden => "forbidden",
            NvError::UnknownOp(_) => "unknown_op",
            NvError::BadArgs(_) => "bad_args",
            NvError::Db(_) | NvError::Internal(_) => "internal",
        }
    }

    /// Ce que l'app reçoit : jamais le détail d'une panne.
    pub fn body(&self) -> serde_json::Value {
        if self.refus_de_la_base() {
            return json!({ "code": "refused", "message": "Demande refusée : une donnée n'est pas acceptée." });
        }
        let message = match self {
            NvError::Db(_) | NvError::Internal(_) => {
                "Le serveur a rencontré un problème. Réessaie dans un instant.".to_string()
            }
            autre => autre.to_string(),
        };
        json!({ "code": self.code(), "message": message })
    }

    /// Vrai pour un refus d'une règle ou une demande invalide (pas une panne).
    pub fn is_refusal(&self) -> bool {
        self.refus_de_la_base() || !matches!(self, NvError::Db(_) | NvError::Internal(_))
    }
}
