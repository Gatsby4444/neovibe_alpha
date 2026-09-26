//! Ce qu'une opération reçoit.
use std::sync::Arc;

use chrono::{DateTime, Utc};
use sqlx::{PgConnection, Postgres, Transaction};

use crate::actor::Actor;
use crate::error::{NvError, NvResult};
use crate::fichiers::Entrepot;

/// Ce qu'il faudra faire APRÈS la validation de la transaction — jamais
/// avant : un fichier effacé pour une écriture finalement annulée serait
/// perdu pour rien.
#[derive(Debug, Clone, PartialEq)]
pub enum AfterCommit {
    /// Supprimer des fichiers d'un coffre.
    DeleteFiles { bucket: String, paths: Vec<String> },
}

/// Le contexte d'une opération.
///
/// - `tx` : la transaction. Tout ce que fait l'opération y passe ; le
///   guichet la valide, la preuve l'annule.
/// - `now` : l'heure de la base au début de la transaction (`now()` en
///   SQL). Les règles lisent CETTE heure, jamais une horloge cachée : c'est
///   la même que celle des requêtes, et la preuve la partage entre l'ancien
///   et le nouveau gardien.
/// - `entrepot` : l'entrepôt des fichiers (réel au serveur, factice dans la
///   preuve).
pub struct Ctx {
    pub tx: Transaction<'static, Postgres>,
    pub actor: Actor,
    pub now: DateTime<Utc>,
    pub after_commit: Vec<AfterCommit>,
    pub entrepot: Option<Arc<dyn Entrepot>>,
}

impl Ctx {
    /// Ouvre un contexte sur une transaction déjà commencée.
    pub async fn open(
        mut tx: Transaction<'static, Postgres>,
        actor: Actor,
        entrepot: Option<Arc<dyn Entrepot>>,
    ) -> NvResult<Self> {
        let now: DateTime<Utc> = sqlx::query_scalar("select now()").fetch_one(&mut *tx).await?;
        Ok(Ctx { tx, actor, now, after_commit: Vec::new(), entrepot })
    }

    /// La connexion de la transaction, pour les requêtes.
    pub fn db(&mut self) -> &mut PgConnection {
        &mut self.tx
    }

    /// L'entrepôt des fichiers.
    pub fn entrepot(&self) -> NvResult<Arc<dyn Entrepot>> {
        self.entrepot.clone().ok_or_else(|| NvError::Internal("aucun entrepôt de fichiers configuré".into()))
    }
}
