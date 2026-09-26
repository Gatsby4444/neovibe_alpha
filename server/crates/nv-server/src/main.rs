//! Le serveur NeoVibe.
//!
//! Configuration par variables d'environnement (jamais de secret dans le
//! dépôt) — voir [`config::Config`].
mod config;
mod routes;

use std::sync::Arc;

use anyhow::Context;
use sqlx::postgres::PgPoolOptions;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();
    let config = config::Config::from_env()?;
    let pool = PgPoolOptions::new()
        .max_connections(config.db_connections)
        .connect(&config.database_url)
        .await
        .context("connexion à la base")?;
    let etat = Arc::new(routes::Etat::new(pool));
    let app = routes::router(etat);
    let ecoute = tokio::net::TcpListener::bind(&config.adresse)
        .await
        .with_context(|| format!("écoute sur {}", config.adresse))?;
    tracing::info!("NeoVibe écoute sur {}", config.adresse);
    axum::serve(ecoute, app).await.context("serveur")?;
    Ok(())
}
