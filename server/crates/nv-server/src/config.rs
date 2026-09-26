//! La configuration, lue dans l'environnement.
//!
//! | Variable | Sens | Par défaut |
//! |---|---|---|
//! | `NV_DATABASE_URL` | la base | la base locale de travail (port 54329) |
//! | `NV_ADRESSE` | où écouter | `127.0.0.1:8787` |
//! | `NV_DB_CONNEXIONS` | taille du réservoir de connexions | `20` |
use anyhow::Context;

pub struct Config {
    pub database_url: String,
    pub adresse: String,
    pub db_connections: u32,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Config {
            database_url: std::env::var("NV_DATABASE_URL")
                .unwrap_or_else(|_| "postgres://postgres:neovibe@localhost:54329/postgres".into()),
            adresse: std::env::var("NV_ADRESSE").unwrap_or_else(|_| "127.0.0.1:8787".into()),
            db_connections: std::env::var("NV_DB_CONNEXIONS")
                .ok()
                .map(|s| s.parse().context("NV_DB_CONNEXIONS"))
                .transpose()?
                .unwrap_or(20),
        })
    }
}
