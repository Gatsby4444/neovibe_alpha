//! **Le direct** — la connexion permanente avec l'app (WebSocket,
//! `GET /v1/direct`).
//!
//! Le protocole (messages JSON) :
//!
//! | L'app envoie | Le serveur répond |
//! |---|---|
//! | `{"type":"auth","token":…}` (en premier, puis à chaque renouvellement du badge) | `{"type":"pret"}` |
//! | `{"type":"abonner","ref":…,"sujet":"messages:conversation_id=…"}` | `{"type":"abonne","ref":…}` ou `{"type":"erreur","ref":…,"message":…}` |
//! | `{"type":"desabonner","ref":…}` | — |
//! | `{"type":"diffuser","sujet":"typing:…","contenu":{…}}` | — |
//! | `{"type":"ping"}` | `{"type":"pong"}` |
//!
//! Et le serveur pousse : `{"type":"changement","ref":…,"op":"INSERT|UPDATE|DELETE","ligne":{…}}`,
//! `{"type":"diffusion","ref":…,"contenu":{…}}`, et `{"type":"expire"}` avant
//! de fermer une connexion dont le badge a expiré sans être renouvelé.
//!
//! La source des changements est la base elle-même (canal `nv_direct`,
//! `server/migrations/…_le_direct.sql`) : tous les chemins y passent. Les
//! diffusions passent aussi par la base (`nv_diffusion`) : plusieurs
//! serveurs les partagent.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::Response;
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use sqlx::postgres::PgListener;
use sqlx::PgPool;
use tokio::sync::mpsc;
use uuid::Uuid;

use nv_app::direct::{self, Sujet, Table};

use crate::routes::Etat;

struct Connexion {
    moi: Uuid,
    abonnements: HashMap<String, Sujet>,
    diffusions: HashMap<String, String>,
    envoi: mpsc::UnboundedSender<String>,
}

/// Les connexions ouvertes.
#[derive(Default)]
pub struct Hub {
    suivant: AtomicU64,
    connexions: Mutex<HashMap<u64, Connexion>>,
}

impl Hub {
    fn ajouter(&self, c: Connexion) -> u64 {
        let id = self.suivant.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut m) = self.connexions.lock() {
            m.insert(id, c);
        }
        id
    }

    fn retirer(&self, id: u64) {
        if let Ok(mut m) = self.connexions.lock() {
            m.remove(&id);
        }
    }

    fn avec<R>(&self, id: u64, f: impl FnOnce(&mut Connexion) -> R) -> Option<R> {
        self.connexions.lock().ok().and_then(|mut m| m.get_mut(&id).map(f))
    }

    /// Les abonnés d'une table : (connexion, compte, référence, sujet).
    fn abonnes(&self, t: Table) -> Vec<(u64, Uuid, String, Sujet)> {
        let Ok(m) = self.connexions.lock() else { return vec![] };
        m.iter()
            .flat_map(|(id, c)| {
                c.abonnements
                    .iter()
                    .filter(|(_, s)| s.table == t)
                    .map(|(r, s)| (*id, c.moi, r.clone(), s.clone()))
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    fn envoyer(&self, id: u64, texte: String) {
        if let Ok(m) = self.connexions.lock() {
            if let Some(c) = m.get(&id) {
                let _ = c.envoi.send(texte);
            }
        }
    }
}

/// Écoute la base et distribue. Se relance si la connexion d'écoute tombe.
pub fn ecouter(pool: PgPool, hub: Arc<Hub>) {
    tokio::spawn(async move {
        loop {
            if let Err(e) = boucle(&pool, &hub).await {
                tracing::error!("direct : écoute interrompue ({e}), reprise dans 2 s");
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

async fn boucle(pool: &PgPool, hub: &Hub) -> Result<(), sqlx::Error> {
    let mut ecoute = PgListener::connect_with(pool).await?;
    ecoute.listen_all(["nv_direct", "nv_diffusion"]).await?;
    loop {
        let n = ecoute.recv().await?;
        let Ok(annonce) = serde_json::from_str::<Value>(n.payload()) else { continue };
        if n.channel() == "nv_diffusion" {
            distribuer_diffusion(hub, &annonce);
        } else if let Err(e) = distribuer_changement(pool, hub, &annonce).await {
            tracing::error!("direct : {e}");
        }
    }
}

fn distribuer_diffusion(hub: &Hub, annonce: &Value) {
    let (Some(sujet), Some(de)) = (annonce.get("sujet").and_then(Value::as_str), annonce.get("de").and_then(Value::as_str)) else {
        return;
    };
    let contenu = annonce.get("contenu").cloned().unwrap_or(Value::Null);
    let Ok(m) = hub.connexions.lock() else { return };
    for c in m.values() {
        if c.moi.to_string() == de {
            continue; // l'émetteur ne reçoit pas sa propre diffusion
        }
        for (r, s) in &c.diffusions {
            if s == sujet {
                let _ = c.envoi.send(json!({ "type": "diffusion", "ref": r, "contenu": contenu }).to_string());
            }
        }
    }
}

async fn distribuer_changement(pool: &PgPool, hub: &Hub, annonce: &Value) -> Result<(), nv_core::NvError> {
    let Some(t) = annonce.get("t").and_then(Value::as_str).and_then(Table::depuis) else { return Ok(()) };
    let op = annonce.get("op").and_then(Value::as_str).unwrap_or("");
    let ligne = annonce.get("ligne").cloned().unwrap_or(Value::Null);
    let abonnes: Vec<_> = hub.abonnes(t).into_iter().filter(|(_, _, _, s)| s.correspond(&ligne)).collect();
    if abonnes.is_empty() {
        return Ok(());
    }
    let mut db = pool.acquire().await?;
    for (id, moi, reference, sujet) in abonnes {
        if op == "DELETE" {
            // La ligne n'existe plus : on ne peut plus la relire. Un sujet
            // filtré a été autorisé à l'abonnement ; sans filtre, seules les
            // tables dont la ligne dit à qui elle appartient sont envoyées.
            let concerne = sujet.filtre.is_some()
                || match t {
                    Table::Connections => [ligne.get("user_low"), ligne.get("user_high")]
                        .iter()
                        .any(|v| v.and_then(Value::as_str) == Some(moi.to_string().as_str())),
                    Table::EventGroupMembers => ligne.get("user_id").and_then(Value::as_str) == Some(moi.to_string().as_str()),
                    _ => false,
                };
            if concerne {
                let cle: serde_json::Map<String, Value> =
                    t.cle().iter().filter_map(|c| ligne.get(*c).map(|v| (c.to_string(), v.clone()))).collect();
                hub.envoyer(id, direct::message_changement(&reference, op, Value::Object(cle)).to_string());
            }
            continue;
        }
        if let Some(complete) = direct::ligne_visible(&mut db, moi, t, &ligne).await? {
            hub.envoyer(id, direct::message_changement(&reference, op, complete).to_string());
        }
    }
    Ok(())
}

/// `GET /v1/direct` : ouvre la connexion permanente.
pub async fn ouvrir(ws: WebSocketUpgrade, State(etat): State<Arc<Etat>>) -> Response {
    ws.on_upgrade(move |socket| session(socket, etat))
}

fn erreur(reference: &str, message: &str) -> String {
    json!({ "type": "erreur", "ref": reference, "message": message }).to_string()
}

async fn session(socket: WebSocket, etat: Arc<Etat>) {
    let (mut sortie, mut entree) = socket.split();
    // 1. Le badge, dans les 10 secondes.
    let premier = tokio::time::timeout(Duration::from_secs(10), entree.next()).await;
    let Ok(Some(Ok(Message::Text(texte)))) = premier else { return };
    let Some((moi, mut expire)) = serde_json::from_str::<Value>(&texte)
        .ok()
        .filter(|v| v.get("type").and_then(Value::as_str) == Some("auth"))
        .and_then(|v| v.get("token").and_then(Value::as_str).map(String::from))
        .and_then(|t| etat.badge.verifier_avec_expiration(&t).ok())
        .map(|(c, _, e)| (c, e))
    else {
        let _ = sortie.send(Message::Text(json!({ "type": "erreur", "message": "Connecte-toi pour continuer." }).to_string().into())).await;
        return;
    };
    let (envoi, mut a_envoyer) = mpsc::unbounded_channel::<String>();
    let id = etat.hub.ajouter(Connexion { moi, abonnements: HashMap::new(), diffusions: HashMap::new(), envoi: envoi.clone() });
    let _ = envoi.send(json!({ "type": "pret" }).to_string());

    let ecrivain = tokio::spawn(async move {
        while let Some(t) = a_envoyer.recv().await {
            if sortie.send(Message::Text(t.into())).await.is_err() {
                break;
            }
        }
    });
    let mut horloge = tokio::time::interval(Duration::from_secs(30));
    loop {
        tokio::select! {
            _ = horloge.tick() => {
                let maintenant = chrono::Utc::now().timestamp();
                if maintenant > expire + 60 {
                    let _ = envoi.send(json!({ "type": "expire" }).to_string());
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    break;
                }
            }
            recu = entree.next() => {
                let Some(Ok(message)) = recu else { break };
                let Message::Text(texte) = message else { continue };
                let Ok(v) = serde_json::from_str::<Value>(&texte) else { continue };
                let reference = v.get("ref").and_then(Value::as_str).unwrap_or_default().to_string();
                match v.get("type").and_then(Value::as_str).unwrap_or_default() {
                    "ping" => { let _ = envoi.send(json!({ "type": "pong" }).to_string()); }
                    "auth" => {
                        let nouveau = v.get("token").and_then(Value::as_str).and_then(|t| etat.badge.verifier_avec_expiration(t).ok());
                        match nouveau {
                            Some((c, _, e)) if c == moi => { expire = e; let _ = envoi.send(json!({ "type": "pret" }).to_string()); }
                            _ => { let _ = envoi.send(erreur("", "Badge refusé.")); }
                        }
                    }
                    "abonner" => {
                        let sujet = v.get("sujet").and_then(Value::as_str).unwrap_or_default().to_string();
                        let reponse = abonner(&etat, id, moi, &reference, &sujet).await;
                        let _ = envoi.send(reponse);
                    }
                    "desabonner" => {
                        etat.hub.avec(id, |c| { c.abonnements.remove(&reference); c.diffusions.remove(&reference); });
                    }
                    "diffuser" => {
                        let sujet = v.get("sujet").and_then(Value::as_str).unwrap_or_default().to_string();
                        let contenu = v.get("contenu").cloned().unwrap_or(Value::Null);
                        if let Err(e) = diffuser(&etat, moi, &sujet, contenu).await {
                            let _ = envoi.send(erreur(&reference, &e));
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    etat.hub.retirer(id);
    ecrivain.abort();
}

async fn abonner(etat: &Etat, id: u64, moi: Uuid, reference: &str, sujet: &str) -> String {
    let Ok(mut db) = etat.pool.acquire().await else { return erreur(reference, "Serveur occupé, réessaie.") };
    if sujet.starts_with("typing:") {
        return match direct::peut_diffuser(&mut db, moi, sujet).await {
            Ok(true) => {
                etat.hub.avec(id, |c| c.diffusions.insert(reference.to_string(), sujet.to_string()));
                json!({ "type": "abonne", "ref": reference }).to_string()
            }
            _ => erreur(reference, "Tu n'as pas accès à cette opération."),
        };
    }
    let s = match Sujet::lire(sujet) {
        Ok(s) => s,
        Err(e) => return erreur(reference, &e.to_string()),
    };
    match direct::autoriser(&mut db, moi, &s).await {
        Ok(()) => {
            etat.hub.avec(id, |c| c.abonnements.insert(reference.to_string(), s));
            json!({ "type": "abonne", "ref": reference }).to_string()
        }
        Err(e) => erreur(reference, &e.to_string()),
    }
}

async fn diffuser(etat: &Etat, moi: Uuid, sujet: &str, contenu: Value) -> Result<(), String> {
    let mut db = etat.pool.acquire().await.map_err(|e| e.to_string())?;
    if !direct::peut_diffuser(&mut db, moi, sujet).await.map_err(|e| e.to_string())? {
        return Err("Tu n'as pas accès à cette opération.".into());
    }
    let annonce = json!({ "sujet": sujet, "de": moi, "contenu": contenu }).to_string();
    if annonce.len() > 4000 {
        return Err("Diffusion trop longue.".into());
    }
    sqlx::query("select pg_notify('nv_diffusion', $1)")
        .bind(annonce)
        .execute(&mut *db)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}
