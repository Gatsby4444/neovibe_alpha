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
use std::net::{IpAddr, SocketAddr};
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

/// L'adresse du téléphone, celle que comptent les limiteurs.
///
/// Derrière le portier https du VPS, toute connexion vient de la machine
/// elle-même (127.0.0.1) : compter cette adresse mettrait tous les
/// utilisateurs dans le même compteur, et vingt connexions en une minute
/// bloqueraient tout le monde. Le portier écrit l'adresse du téléphone en
/// DERNIER dans `X-Forwarded-For` (Caddy remplace ce qu'envoie un client
/// qui n'est pas un portier de confiance) : c'est celle-là qu'on prend.
///
/// L'en-tête n'est lu que si `NV_PORTIER_LOCAL` le dit ET si la connexion
/// vient de la machine elle-même : un téléphone qui l'écrirait lui-même en
/// joignant le serveur directement n'est pas cru.
pub fn adresse_client(portier_local: bool, pair: SocketAddr, entetes: &HeaderMap) -> IpAddr {
    if !(portier_local && pair.ip().is_loopback()) {
        return pair.ip();
    }
    entetes
        .get_all("x-forwarded-for")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .last()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(pair.ip())
}

/// La clé sous laquelle un limiteur compte une adresse.
///
/// En IPv4, l'adresse elle-même. En IPv6, son **bloc /64** : une simple box
/// reçoit au moins 2^64 adresses, et compter chacune laisserait un
/// attaquant en changer à chaque essai (relevé par le gardien-securite le
/// 2026-09-29). Une adresse IPv4 écrite en IPv6 (`::ffff:1.2.3.4`) est
/// comptée comme l'IPv4 qu'elle est.
pub fn cle_de_comptage(ip: IpAddr) -> String {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => {
            let s = v6.segments();
            format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
        }
    }
}

/// La clé sous laquelle le limiteur par compte compte une adresse e-mail :
/// son empreinte (SHA-256, 64 caractères), jamais l'adresse elle-même.
/// L'adresse arrive telle que le client l'envoie, sans limite de taille
/// (jusqu'à ~2 Mo par demande) : gardée telle quelle, elle aurait permis de
/// remplir la mémoire du serveur (relevé par le relecteur le 2026-09-29).
/// Une entrée du limiteur a ainsi toujours la même petite taille.
pub fn cle_de_compte(email: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(email.trim().to_lowercase().as_bytes()))
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
    ConnectInfo(pair): ConnectInfo<SocketAddr>,
    entetes: HeaderMap,
    Json(c): Json<Inscription>,
) -> Result<Json<Value>, ErreurHttp> {
    etat.limite_comptes.compter(&cle_de_comptage(adresse_client(etat.portier_local, pair, &entetes)))?;
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
    ConnectInfo(pair): ConnectInfo<SocketAddr>,
    entetes: HeaderMap,
    Json(c): Json<Connexion>,
) -> Result<Json<Value>, ErreurHttp> {
    etat.limite_comptes.compter(&cle_de_comptage(adresse_client(etat.portier_local, pair, &entetes)))?;
    // Et par COMPTE visé : qui dispose de beaucoup d'adresses n'essaie pas
    // plus de mots de passe sur un même compte. (Le revers, assumé : un
    // tiers peut retarder d'une minute la connexion d'un compte dont il
    // connaît l'adresse e-mail.)
    etat.limite_par_compte.compter(&cle_de_compte(&c.email))?;
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
    ConnectInfo(pair): ConnectInfo<SocketAddr>,
    entetes: HeaderMap,
    Json(r): Json<Renouvellement>,
) -> Result<Json<Value>, ErreurHttp> {
    etat.limite_renouvellement.compter(&cle_de_comptage(adresse_client(etat.portier_local, pair, &entetes)))?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn entetes(xff: &[&str]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for v in xff {
            h.append("x-forwarded-for", v.parse().unwrap_or_else(|_| panic!("{v}")));
        }
        h
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap_or_else(|_| panic!("{s}"))
    }

    const LOCAL: &str = "127.0.0.1:50000";
    const DEHORS: &str = "203.0.113.9:50000";

    fn pair(s: &str) -> SocketAddr {
        s.parse().unwrap_or_else(|_| panic!("{s}"))
    }

    #[test]
    fn derriere_le_portier_on_compte_le_telephone() {
        let e = entetes(&["198.51.100.7"]);
        assert_eq!(adresse_client(true, pair(LOCAL), &e), ip("198.51.100.7"));
    }

    #[test]
    fn la_derniere_adresse_est_celle_du_portier() {
        // Ce qu'un téléphone écrit lui-même est devant ; le portier ajoute
        // la vraie adresse en dernier.
        let e = entetes(&["1.2.3.4, 198.51.100.7"]);
        assert_eq!(adresse_client(true, pair(LOCAL), &e), ip("198.51.100.7"));
        let e = entetes(&["1.2.3.4", "198.51.100.7"]);
        assert_eq!(adresse_client(true, pair(LOCAL), &e), ip("198.51.100.7"));
    }

    #[test]
    fn sans_portier_l_entete_n_est_pas_cru() {
        let e = entetes(&["198.51.100.7"]);
        assert_eq!(adresse_client(false, pair(LOCAL), &e), ip("127.0.0.1"));
    }

    #[test]
    fn une_connexion_du_dehors_n_est_pas_crue() {
        let e = entetes(&["198.51.100.7"]);
        assert_eq!(adresse_client(true, pair(DEHORS), &e), ip("203.0.113.9"));
    }

    #[test]
    fn un_bloc_ipv6_est_un_seul_compteur() {
        let a = cle_de_comptage(ip("2001:db8:1:2:aaaa::1"));
        let b = cle_de_comptage(ip("2001:db8:1:2:ffff:1:2:3"));
        assert_eq!(a, b);
        assert_eq!(a, "2001:db8:1:2::/64");
        assert_ne!(a, cle_de_comptage(ip("2001:db8:1:3::1")));
    }

    #[test]
    fn une_ipv4_compte_pour_elle_meme() {
        assert_eq!(cle_de_comptage(ip("198.51.100.7")), "198.51.100.7");
        assert_ne!(cle_de_comptage(ip("198.51.100.7")), cle_de_comptage(ip("198.51.100.8")));
        assert_eq!(cle_de_comptage(ip("::ffff:198.51.100.7")), "198.51.100.7");
    }

    #[test]
    fn la_cle_d_un_compte_a_une_taille_fixe() {
        let enorme = "a".repeat(2_000_000);
        assert_eq!(cle_de_compte(&enorme).len(), 64);
        assert_eq!(cle_de_compte(" Jay@Exemple.fr "), cle_de_compte("jay@exemple.fr"));
        assert_ne!(cle_de_compte("jay@exemple.fr"), cle_de_compte("mimi@exemple.fr"));
    }

    #[test]
    fn un_entete_absent_ou_illisible_rend_la_connexion() {
        assert_eq!(adresse_client(true, pair(LOCAL), &entetes(&[])), ip("127.0.0.1"));
        assert_eq!(adresse_client(true, pair(LOCAL), &entetes(&["n'importe quoi"])), ip("127.0.0.1"));
    }
}
