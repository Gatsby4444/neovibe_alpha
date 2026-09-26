//! Le serveur NeoVibe.
//!
//! Configuration par variables d'environnement (jamais de secret dans le
//! dépôt) — voir [`config::Config`].
//!
//! `nv-server nouvelle-cle` affiche une nouvelle clé de badge, à ranger dans
//! `NV_BADGE_CLE` (configuration du VPS).
mod auth;
mod config;
mod routes;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use base64::Engine;
use sqlx::postgres::PgPoolOptions;
use tracing_subscriber::EnvFilter;

use nv_app::comptes::badge::Badge;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("nouvelle-cle") {
        println!("{}", base64::engine::general_purpose::STANDARD.encode(Badge::nouvelle_cle()));
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
    let etat = Arc::new(routes::Etat::new(pool, badge));
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
