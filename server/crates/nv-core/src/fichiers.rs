//! **L'entrepôt des fichiers**, vu du serveur : une interface.
//!
//! Les octets (photos, vidéos scellées) ne passent pas par le programme :
//! il signe des liens, valables quelques minutes, avec lesquels le téléphone
//! dépose ou lit directement dans l'entrepôt (compatible S3 : AWS, R2,
//! SeaweedFS en local…). Le programme ne fait lui-même que les gestes de
//! gestion : ouvrir et terminer un envoi en morceaux, supprimer, vérifier
//! qu'un fichier existe.
//!
//! L'interface permet à la preuve de jouer les règles sans entrepôt réel
//! (un entrepôt factice), et au serveur de changer d'entrepôt sans toucher
//! aux règles.
use futures::future::BoxFuture;

use crate::error::NvResult;

/// Un morceau déjà reçu d'un envoi en morceaux.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Morceau {
    pub numero: u16,
    pub etag: String,
    pub taille: u64,
}

/// L'entrepôt.
pub trait Entrepot: Send + Sync {
    /// Un lien signé pour LIRE un fichier pendant `duree_s` secondes.
    fn lien_lecture(&self, bucket: &str, chemin: &str, duree_s: u64) -> NvResult<String>;

    /// Un lien signé pour DÉPOSER un fichier entier (PUT). Le type et la
    /// taille sont signés : l'entrepôt refuse un dépôt qui ne les respecte pas.
    fn lien_depot(&self, bucket: &str, chemin: &str, type_: &str, taille: u64, duree_s: u64) -> NvResult<String>;

    /// Un lien signé pour déposer le morceau `numero` d'un envoi.
    fn lien_morceau(&self, bucket: &str, chemin: &str, envoi: &str, numero: u16, duree_s: u64) -> NvResult<String>;

    /// Ouvre un envoi en morceaux ; rend son identifiant.
    fn ouvrir_envoi<'a>(&'a self, bucket: &'a str, chemin: &'a str, type_: &'a str) -> BoxFuture<'a, NvResult<String>>;

    /// Les morceaux déjà reçus ; `None` si l'envoi n'existe plus.
    fn morceaux<'a>(&'a self, bucket: &'a str, chemin: &'a str, envoi: &'a str)
        -> BoxFuture<'a, NvResult<Option<Vec<Morceau>>>>;

    /// Assemble les morceaux reçus en un fichier.
    fn terminer_envoi<'a>(&'a self, bucket: &'a str, chemin: &'a str, envoi: &'a str, morceaux: Vec<Morceau>)
        -> BoxFuture<'a, NvResult<()>>;

    /// Abandonne un envoi (ses morceaux sont effacés).
    fn abandonner_envoi<'a>(&'a self, bucket: &'a str, chemin: &'a str, envoi: &'a str) -> BoxFuture<'a, NvResult<()>>;

    /// La taille d'un fichier, ou `None` s'il n'existe pas.
    fn taille<'a>(&'a self, bucket: &'a str, chemin: &'a str) -> BoxFuture<'a, NvResult<Option<u64>>>;

    /// Supprime des fichiers (un fichier absent n'est pas une erreur).
    fn supprimer<'a>(&'a self, bucket: &'a str, chemins: Vec<String>) -> BoxFuture<'a, NvResult<()>>;
}
