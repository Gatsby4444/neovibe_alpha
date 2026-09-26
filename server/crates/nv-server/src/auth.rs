//! Les routes de connexion : `/v1/auth/…`.
//!
//! | Route | Corps | Réponse |
//! |---|---|---|
//! | `POST /v1/auth/inscription` | `{email, password, device_hash}` | les jetons |
//! | `POST /v1/auth/connexion` | `{email, password}` | les jetons |
//! | `POST /v1/auth/renouveler` | `{refresh_token}` | les jetons |
//! | `POST /v1/auth/deconnexion` | — (badge) | `null` |
//! | `GET /v1/auth/moi` | — (badge) | `{id, email}` |
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, State};
use axum::http::{header, HeaderMap};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_app::comptes::connexion as cx;
use nv_core::{Actor, NvError};

use crate::routes::{ErreurHttp, Etat};

/// Un limiteur simple : `max` demandes par fenêtre, par clé (l'adresse IP).
///
/// Il ne remplace pas une protection devant le serveur (à poser sur le VPS,
/// étape 12) ; il empêche d'essayer des mots de passe en rafale.
pub struct Limiteur {
    fenetre: Duration,
    max: u32,
    compteurs: Mutex<HashMap<String, (Instant, u32)>>,
}

impl Limiteur {
    pub fn new(max: u32, fenetre: Duration) -> Self {
        Limiteur { fenetre, max, compteurs: Mutex::new(HashMap::new()) }
    }

    /// Compte une demande ; refuse au-delà du maximum.
    pub fn compter(&self, cle: &str) -> Result<(), NvError> {
        let mut c = self.compteurs.lock().map_err(|_| NvError::Internal("limiteur".into()))?;
        let maintenant = Instant::now();
        if c.len() > 10_000 {
            c.retain(|_, (debut, _)| maintenant.duration_since(*debut) < self.fenetre);
        }
        let e = c.entry(cle.to_string()).or_insert((maintenant, 0));
        if maintenant.duration_since(e.0) >= self.fenetre {
            *e = (maintenant, 0);
        }
        e.1 += 1;
        if e.1 > self.max {
            return Err(NvError::refused("Trop d'essais. Réessaie dans une minute."));
        }
        Ok(())
    }
}

/// L'appelant d'une demande : son badge, s'il en présente un.
///
/// Un badge présenté mais invalide (expiré, falsifié) est un REFUS, pas un
/// passage en anonyme : l'app doit le renouveler.
pub fn appelant(etat: &Etat, entetes: &HeaderMap) -> Result<(Actor, Option<Uuid>), NvError> {
    let Some(valeur) = entetes.get(header::AUTHORIZATION) else { return Ok((Actor::Anonymous, None)) };
    let texte = valeur.to_str().map_err(|_| NvError::Unauthenticated)?;
    let jeton = texte.strip_prefix("Bearer ").ok_or(NvError::Unauthenticated)?;
    let (compte, session) = etat.badge.verifier(jeton)?;
    Ok((Actor::User(compte), Some(session)))
}

fn appareil(entetes: &HeaderMap) -> Option<String> {
    entetes.get(header::USER_AGENT).and_then(|v| v.to_str().ok()).map(|s| s.chars().take(200).collect())
}

#[derive(Deserialize)]
pub struct Inscription {
    email: String,
    password: String,
    device_hash: Option<String>,
}

pub async fn inscription(
    State(etat): State<Arc<Etat>>,
    ConnectInfo(ip): ConnectInfo<SocketAddr>,
    entetes: HeaderMap,
    Json(c): Json<Inscription>,
) -> Result<Json<Value>, ErreurHttp> {
    etat.limite_comptes.compter(&ip.ip().to_string())?;
    let mut tx = etat.pool.begin().await.map_err(NvError::from)?;
    let jetons = cx::inscrire(&mut tx, &etat.badge, &c.email, &c.password, c.device_hash.as_deref(), appareil(&entetes).as_deref()).await?;
    tx.commit().await.map_err(NvError::from)?;
    Ok(Json(json!(jetons)))
}

#[derive(Deserialize)]
pub struct Connexion {
    email: String,
    password: String,
}

pub async fn connexion(
    State(etat): State<Arc<Etat>>,
    ConnectInfo(ip): ConnectInfo<SocketAddr>,
    entetes: HeaderMap,
    Json(c): Json<Connexion>,
) -> Result<Json<Value>, ErreurHttp> {
    etat.limite_comptes.compter(&ip.ip().to_string())?;
    let mut tx = etat.pool.begin().await.map_err(NvError::from)?;
    let jetons = cx::connecter(&mut tx, &etat.badge, &c.email, &c.password, appareil(&entetes).as_deref()).await?;
    tx.commit().await.map_err(NvError::from)?;
    Ok(Json(json!(jetons)))
}

#[derive(Deserialize)]
pub struct Renouvellement {
    refresh_token: String,
}

pub async fn renouveler(
    State(etat): State<Arc<Etat>>,
    ConnectInfo(ip): ConnectInfo<SocketAddr>,
    Json(r): Json<Renouvellement>,
) -> Result<Json<Value>, ErreurHttp> {
    etat.limite_renouvellement.compter(&ip.ip().to_string())?;
    let mut tx = etat.pool.begin().await.map_err(NvError::from)?;
    let resultat = cx::renouveler(&mut tx, &etat.badge, &r.refresh_token).await;
    // Une réutilisation détectée révoque la session : cette écriture doit
    // tenir même si la réponse est un refus.
    tx.commit().await.map_err(NvError::from)?;
    Ok(Json(json!(resultat?)))
}

pub async fn deconnexion(State(etat): State<Arc<Etat>>, entetes: HeaderMap) -> Result<Json<Value>, ErreurHttp> {
    let (_, session) = appelant(&etat, &entetes)?;
    let session = session.ok_or(NvError::Unauthenticated)?;
    let mut tx = etat.pool.begin().await.map_err(NvError::from)?;
    cx::deconnecter(&mut tx, session).await?;
    tx.commit().await.map_err(NvError::from)?;
    Ok(Json(Value::Null))
}

pub async fn moi(State(etat): State<Arc<Etat>>, entetes: HeaderMap) -> Result<Json<Value>, ErreurHttp> {
    let (actor, _) = appelant(&etat, &entetes)?;
    let compte = actor.uid()?;
    let mut db = etat.pool.acquire().await.map_err(NvError::from)?;
    let email = cx::adresse_du_compte(&mut db, compte).await?.ok_or(NvError::Unauthenticated)?;
    Ok(Json(json!({ "id": compte, "email": email })))
}
