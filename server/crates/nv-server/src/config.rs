//! La configuration, lue dans l'environnement (jamais de secret dans le
//! dépôt).
//!
//! | Variable | Sens | Par défaut |
//! |---|---|---|
//! | `NV_DATABASE_URL` | la base | la base locale de travail (port 54329) |
//! | `NV_ADRESSE` | où écouter | `127.0.0.1:8787` |
//! | `NV_DB_CONNEXIONS` | taille du réservoir de connexions | `20` |
//! | `NV_BADGE_CLE` | la clé des badges (base64, `nv-server nouvelle-cle`) | éphémère (développement) |
//! | `NV_S3_INTERNE` | l'entrepôt, vu du serveur | `http://127.0.0.1:8333` (SeaweedFS local) |
//! | `NV_S3_PUBLIQUE` | l'entrepôt, vu du téléphone (signé dans les liens) | = `NV_S3_INTERNE` |
//! | `NV_S3_REGION` | la région | `us-east-1` |
//! | `NV_S3_CLE`, `NV_S3_SECRET` | les accès à l'entrepôt | obligatoires |
//! | `NV_S3_PREFIXE` | préfixe des noms de buckets | `neovibe-` |
use anyhow::Context;
use base64::Engine;

use nv_entrepot::Reglages;

pub struct Config {
    pub database_url: String,
    pub adresse: String,
    pub db_connections: u32,
    pub badge_cle: Option<Vec<u8>>,
    pub entrepot: Reglages,
}

fn var(nom: &str) -> Option<String> {
    std::env::var(nom).ok().filter(|s| !s.trim().is_empty())
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let interne = var("NV_S3_INTERNE").unwrap_or_else(|| "http://127.0.0.1:8333".into());
        let publique = var("NV_S3_PUBLIQUE").unwrap_or_else(|| interne.clone());
        Ok(Config {
            database_url: var("NV_DATABASE_URL")
                .unwrap_or_else(|| "postgres://postgres:neovibe@localhost:54329/postgres".into()),
            adresse: var("NV_ADRESSE").unwrap_or_else(|| "127.0.0.1:8787".into()),
            db_connections: var("NV_DB_CONNEXIONS")
                .map(|s| s.parse().context("NV_DB_CONNEXIONS"))
                .transpose()?
                .unwrap_or(20),
            badge_cle: var("NV_BADGE_CLE")
                .map(|s| base64::engine::general_purpose::STANDARD.decode(s.trim()).context("NV_BADGE_CLE"))
                .transpose()?,
            entrepot: Reglages {
                interne: interne.parse().context("NV_S3_INTERNE")?,
                publique: publique.parse().context("NV_S3_PUBLIQUE")?,
                region: var("NV_S3_REGION").unwrap_or_else(|| "us-east-1".into()),
                cle: var("NV_S3_CLE").context("NV_S3_CLE manquante")?,
                secret: var("NV_S3_SECRET").context("NV_S3_SECRET manquante")?,
                prefixe: var("NV_S3_PREFIXE").unwrap_or_else(|| "neovibe-".into()),
            },
        })
    }
}
