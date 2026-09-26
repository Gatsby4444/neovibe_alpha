//! Le balai des fichiers, contre la base locale (transaction annulée) : il
//! efface ce dont le délai est passé, épargne ce que la modération retient,
//! et ne retire une pierre tombale qu'APRÈS l'effacement réussi.
use std::sync::Mutex;

use futures::future::BoxFuture;
use futures::FutureExt;
use nv_core::fichiers::{Entrepot, Morceau};
use nv_core::{NvError, NvResult};
use sqlx::PgPool;

#[derive(Default)]
struct Temoin {
    effaces: Mutex<Vec<(String, String)>>,
    en_panne: bool,
}

impl Entrepot for Temoin {
    fn lien_lecture(&self, _: &str, _: &str, _: u64) -> NvResult<String> {
        Ok(String::new())
    }
    fn lien_depot(&self, _: &str, _: &str, _: &str, _: u64, _: u64) -> NvResult<String> {
        Ok(String::new())
    }
    fn lien_morceau(&self, _: &str, _: &str, _: &str, _: u16, _: u64) -> NvResult<String> {
        Ok(String::new())
    }
    fn ouvrir_envoi<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<String>> {
        async { Ok(String::new()) }.boxed()
    }
    fn morceaux<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<Option<Vec<Morceau>>>> {
        async { Ok(None) }.boxed()
    }
    fn terminer_envoi<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str, _: Vec<Morceau>) -> BoxFuture<'a, NvResult<()>> {
        async { Ok(()) }.boxed()
    }
    fn abandonner_envoi<'a>(&'a self, _: &'a str, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<()>> {
        async { Ok(()) }.boxed()
    }
    fn taille<'a>(&'a self, _: &'a str, _: &'a str) -> BoxFuture<'a, NvResult<Option<u64>>> {
        async { Ok(None) }.boxed()
    }
    fn supprimer<'a>(&'a self, bucket: &'a str, chemins: Vec<String>) -> BoxFuture<'a, NvResult<()>> {
        async move {
            if self.en_panne {
                return Err(NvError::Internal("entrepôt en panne".into()));
            }
            if let Ok(mut e) = self.effaces.lock() {
                e.extend(chemins.into_iter().map(|c| (bucket.to_string(), c)));
            }
            Ok(())
        }
        .boxed()
    }
}

async fn pool() -> PgPool {
    match PgPool::connect("postgres://postgres:neovibe@localhost:54329/postgres").await {
        Ok(p) => p,
        Err(e) => panic!("base locale : {e}"),
    }
}

#[tokio::test]
async fn le_balai_efface_epargne_et_reessaie() -> Result<(), NvError> {
    let pool = pool().await;
    let mut tx = pool.begin().await?;
    sqlx::raw_sql(
        "delete from public.storage_tombstones;
         insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after) values
           ('library', 'a/du.jpg', 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', now() - interval '1 day'),
           ('stories', 'a/retenu.jpg', 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', now() - interval '1 day'),
           ('library', 'a/pas_encore.jpg', 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', now() + interval '1 day');
         insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang)
           values ('content', gen_random_uuid(), 'stories', 'a/retenu.jpg', 1);",
    )
    .execute(&mut *tx)
    .await?;

    // Entrepôt en panne : rien n'est retiré, tout sera réessayé.
    let panne = Temoin { en_panne: true, ..Default::default() };
    assert!(nv_app::fichiers::balai::balayer(&mut tx, &panne).await.is_err());
    let restent: i64 = sqlx::query_scalar("select count(*) from public.storage_tombstones").fetch_one(&mut *tx).await?;
    assert_eq!(restent, 3);

    let t = Temoin::default();
    let bilan = nv_app::fichiers::balai::balayer(&mut tx, &t).await?;
    assert_eq!(bilan, "1 fichier(s) effacé(s)");
    let effaces = t.effaces.lock().map(|e| e.clone()).unwrap_or_default();
    assert_eq!(effaces, vec![("library".to_string(), "a/du.jpg".to_string())]);
    let restent: Vec<String> = sqlx::query_scalar("select object_name from public.storage_tombstones order by 1")
        .fetch_all(&mut *tx)
        .await?;
    assert_eq!(restent, vec!["a/pas_encore.jpg".to_string(), "a/retenu.jpg".to_string()]);
    tx.rollback().await?;
    Ok(())
}
