//! **Le réveil** : les tâches automatiques (les balais).
//!
//! Remplace le réveil de l'ancienne base (pg_cron). Trois différences
//! voulues :
//! - chaque passage est JOURNALISÉ (`nv.job_runs`) : un échec se lit ;
//! - chaque tâche prend un verrou de la base avant de tourner : sur
//!   plusieurs machines, une seule l'exécute ;
//! - chaque passage est UNE transaction : une tâche en échec n'emporte
//!   qu'elle-même (leçon du 2026-08-10 : « un job = une transaction »).
use std::sync::Arc;
use std::time::Duration;

use chrono::{Timelike, Utc};
use futures::future::BoxFuture;
use sqlx::{PgConnection, PgPool};

use nv_core::fichiers::Entrepot;
use nv_core::NvResult;

/// Quand une tâche tourne.
#[derive(Clone, Copy, Debug)]
pub enum Rythme {
    /// Toutes les N secondes.
    Toutes(u64),
    /// Chaque heure, à la minute donnée.
    ChaqueHeureA(u32),
    /// Chaque jour, à l'heure et à la minute données (UTC).
    ChaqueJourA(u32, u32),
}

impl Rythme {
    /// Le délai avant le prochain passage.
    pub fn prochain(&self) -> Duration {
        let maintenant = Utc::now();
        match *self {
            Rythme::Toutes(s) => Duration::from_secs(s),
            Rythme::ChaqueHeureA(m) => {
                let ecoule = maintenant.minute() * 60 + maintenant.second();
                let cible = m * 60;
                let s = if cible > ecoule { cible - ecoule } else { 3600 - ecoule + cible };
                Duration::from_secs(s as u64)
            }
            Rythme::ChaqueJourA(h, m) => {
                let ecoule = maintenant.hour() * 3600 + maintenant.minute() * 60 + maintenant.second();
                let cible = h * 3600 + m * 60;
                let s = if cible > ecoule { cible - ecoule } else { 86_400 - ecoule + cible };
                Duration::from_secs(s as u64)
            }
        }
    }
}

type Geste = for<'a> fn(&'a mut PgConnection, &'a dyn Entrepot) -> BoxFuture<'a, NvResult<String>>;

/// Une tâche : son nom, son rythme, son geste.
pub struct Tache {
    pub nom: &'static str,
    pub rythme: Rythme,
    pub geste: Geste,
}

fn balai_fichiers<'a>(db: &'a mut PgConnection, e: &'a dyn Entrepot) -> BoxFuture<'a, NvResult<String>> {
    Box::pin(nv_app::fichiers::balai::balayer(db, e))
}

fn balai_ping<'a>(db: &'a mut PgConnection, _: &'a dyn Entrepot) -> BoxFuture<'a, NvResult<String>> {
    Box::pin(nv_app::relations::balai_ping(db))
}

fn balai_vues<'a>(db: &'a mut PgConnection, _: &'a dyn Entrepot) -> BoxFuture<'a, NvResult<String>> {
    Box::pin(nv_app::relations::balai_vues(db))
}

fn paliers<'a>(db: &'a mut PgConnection, _: &'a dyn Entrepot) -> BoxFuture<'a, NvResult<String>> {
    Box::pin(nv_app::relations::paliers::recalculer_tous(db))
}

/// Toutes les tâches du serveur — avec le rythme de l'ancien réveil (pg_cron).
pub fn toutes() -> Vec<Tache> {
    vec![
        Tache { nom: "balai_fichiers", rythme: Rythme::Toutes(600), geste: balai_fichiers },
        // neovibe_purge_ping : */5 * * * *
        Tache { nom: "balai_ping", rythme: Rythme::Toutes(300), geste: balai_ping },
        // neovibe_purge_sightings : 17 * * * *
        Tache { nom: "balai_vues", rythme: Rythme::ChaqueHeureA(17), geste: balai_vues },
        // neovibe_tiers : 11 3 * * *
        Tache { nom: "paliers", rythme: Rythme::ChaqueJourA(3, 11), geste: paliers },
    ]
}

/// Un passage, sous verrou, dans sa transaction, journalisé.
pub async fn passer(pool: &PgPool, entrepot: &dyn Entrepot, t: &Tache) -> NvResult<()> {
    let mut tx = pool.begin().await?;
    let verrou: bool = sqlx::query_scalar("select pg_try_advisory_xact_lock(hashtext('nv.tache.' || $1))")
        .bind(t.nom)
        .fetch_one(&mut *tx)
        .await?;
    if !verrou {
        return Ok(()); // une autre machine s'en occupe
    }
    let id: i64 = sqlx::query_scalar("insert into nv.job_runs (job) values ($1) returning id")
        .bind(t.nom)
        .fetch_one(pool)
        .await?;
    let resultat = (t.geste)(&mut tx, entrepot).await;
    let (ok, detail) = match resultat {
        Ok(d) => {
            tx.commit().await?;
            (true, d)
        }
        Err(e) => {
            let _ = tx.rollback().await;
            tracing::error!("tâche {} : {e}", t.nom);
            (false, e.to_string())
        }
    };
    sqlx::query("update nv.job_runs set finished_at = now(), ok = $2, detail = $3 where id = $1")
        .bind(id)
        .bind(ok)
        .bind(detail)
        .execute(pool)
        .await?;
    Ok(())
}

/// Lance le réveil : une boucle par tâche.
pub fn lancer(pool: PgPool, entrepot: Arc<dyn Entrepot>) {
    for t in toutes() {
        let (pool, entrepot) = (pool.clone(), entrepot.clone());
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(t.rythme.prochain()).await;
                if let Err(e) = passer(&pool, entrepot.as_ref(), &t).await {
                    tracing::error!("réveil ({}) : {e}", t.nom);
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::Rythme;

    #[test]
    fn les_rythmes_tombent_dans_l_intervalle() {
        assert_eq!(Rythme::Toutes(300).prochain().as_secs(), 300);
        assert!(Rythme::ChaqueHeureA(29).prochain().as_secs() <= 3600);
        assert!(Rythme::ChaqueJourA(3, 11).prochain().as_secs() <= 86_400);
    }
}
