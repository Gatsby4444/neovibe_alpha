//! Un entrepôt factice pour la preuve : il ne stocke rien et rend des liens
//! reconnaissables. La preuve compare les RÈGLES (qui a le droit de lire,
//! de déposer, de supprimer), pas l'entrepôt.
use futures::future::BoxFuture;
use futures::FutureExt;

use nv_core::fichiers::{Entrepot, Morceau};
use nv_core::NvResult;

pub struct EntrepotFactice {
    /// Les affiches de soirée présentes (relevées dans `storage.objects` de
    /// la base locale, après la mise en place de la situation) : la règle
    /// « l'affiche existe » se prouve ainsi contre ce que l'ancien lisait.
    pub affiches: std::collections::HashSet<String>,
}

impl Entrepot for EntrepotFactice {
    fn lien_lecture(&self, _: &str, _: &str, _: u64) -> NvResult<String> {
        Ok("<lien>".into())
    }
    fn lien_depot(&self, _: &str, _: &str, _: &str, _: u64, _: u64) -> NvResult<String> {
        Ok("<lien>".into())
    }
    fn lien_morceau(&self, _: &str, _: &str, _: &str, _: u16, _: u64) -> NvResult<String> {
        Ok("<lien>".into())
    }
    fn ouvrir_envoi<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<String>> {
        async { Ok("<envoi>".to_string()) }.boxed()
    }
    fn morceaux<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<Option<Vec<Morceau>>>> {
        async { Ok(Some(vec![])) }.boxed()
    }
    fn terminer_envoi<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str, _: Vec<Morceau>) -> BoxFuture<'a, NvResult<()>> {
        async { Ok(()) }.boxed()
    }
    fn abandonner_envoi<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<()>> {
        async { Ok(()) }.boxed()
    }
    fn taille<'a>(&'a self, coffre: &'a str, nom: &'a str) -> BoxFuture<'a, NvResult<Option<u64>>> {
        let present = coffre == "event_posters" && self.affiches.contains(nom);
        async move { Ok(present.then_some(0)) }.boxed()
    }
    fn supprimer<'a>(&'a self, _: &'a str, _: Vec<String>) -> BoxFuture<'a, NvResult<()>> {
        async { Ok(()) }.boxed()
    }
}
