//! Le serveur NeoVibe.
//!
//! Configuration par variables d'environnement (jamais de secret dans le
//! dépôt) — voir [`config::Config`].
//!
//! `nv-server nouvelle-cle` affiche une nouvelle clé de badge, à ranger dans
//! `NV_BADGE_CLE` (configuration du VPS).
mod auth;
mod config;
mod direct;
mod routes;
mod taches;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use base64::Engine;
use sqlx::postgres::PgPoolOptions;
use tracing_subscriber::EnvFilter;

use nv_app::comptes::badge::Badge;
use nv_app::fichiers::regles::COFFRES;
use nv_entrepot::EntrepotS3;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("nouvelle-cle") {
        println!("{}", base64::engine::general_purpose::STANDARD.encode(Badge::nouvelle_cle()));
        return Ok(());
    }
    // Le SQL qui éteint l'ancien gardien, pour le propriétaire des tables :
    // `nv-server eteindre-l-ancien-gardien | sudo -u postgres psql -d neovibe`.
    if std::env::args().nth(1).as_deref() == Some("eteindre-l-ancien-gardien") {
        print!("{}", nv_app::ancien_gardien::sql_pour_les_eteindre());
        return Ok(());
    }
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();
    let config = config::Config::from_env()?;
    let badge = match &config.badge_cle {
        Some(cle) => Badge::depuis_octets(cle).map_err(|e| anyhow::anyhow!("{e}"))?,
        None => {
            tracing::warn!("NV_BADGE_CLE absente : clé éphémère (développement — les badges ne survivront pas au redémarrage)");
            Badge::ephemere()
        }
    };
    let pool = PgPoolOptions::new()
        .max_connections(config.db_connections)
        .connect(&config.database_url)
        .await
        .context("connexion à la base")?;
    // Le serveur n'est juste qu'avec l'ancien gardien éteint (nv_app::ancien_gardien).
    let allumes = nv_app::ancien_gardien::encore_allumes(&pool).await.context("état de l'ancien gardien")?;
    if !allumes.is_empty() {
        anyhow::bail!(
            "l'ancien gardien est encore allumé ({}) : le serveur referait son travail en double. \
             L'éteindre : nv-server eteindre-l-ancien-gardien | psql (en propriétaire des tables)",
            allumes.join(", ")
        );
    }
    let entrepot = EntrepotS3::new(config.entrepot.clone()).map_err(|e| anyhow::anyhow!("{e}"))?;
    entrepot.preparer(&COFFRES).await.map_err(|e| anyhow::anyhow!("{e}"))?;
    let entrepot: Arc<dyn nv_core::fichiers::Entrepot> = Arc::new(entrepot);
    taches::lancer(pool.clone(), entrepot.clone());
    let etat = Arc::new(routes::Etat::new(pool, badge, entrepot, config.portier_local));
    direct::ecouter(etat.pool.clone(), etat.hub.clone());
    let app = routes::router(etat);
    let ecoute = tokio::net::TcpListener::bind(&config.adresse)
        .await
        .with_context(|| format!("écoute sur {}", config.adresse))?;
    tracing::info!("NeoVibe écoute sur {}", config.adresse);
    axum::serve(ecoute, app.into_make_service_with_connect_info::<SocketAddr>())
        .await
        .context("serveur")?;
    Ok(())
}
