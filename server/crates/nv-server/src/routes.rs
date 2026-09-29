//! Les routes HTTP : le guichet commun à tous les domaines.
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::Value;
use sqlx::PgPool;

use nv_app::comptes::badge::Badge;
use nv_core::fichiers::Entrepot;
use nv_core::ops::OpFn;
use nv_core::{AfterCommit, Ctx, NvError};

use crate::auth::{self, Limiteur};

/// L'état partagé par les routes.
pub struct Etat {
    pub pool: PgPool,
    pub ops: HashMap<&'static str, OpFn>,
    pub badge: Badge,
    pub entrepot: Arc<dyn Entrepot>,
    pub hub: Arc<crate::direct::Hub>,
    pub limite_comptes: Limiteur,
    pub limite_renouvellement: Limiteur,
    /// Les connexions par compte visé (l'adresse e-mail), en plus de
    /// l'adresse du téléphone.
    pub limite_par_compte: Limiteur,
    /// Le serveur est derrière un portier https sur la même machine
    /// (`NV_PORTIER_LOCAL`) : voir [`auth::adresse_client`].
    pub portier_local: bool,
}

impl Etat {
    pub fn new(pool: PgPool, badge: Badge, entrepot: Arc<dyn Entrepot>, portier_local: bool) -> Self {
        let ops = nv_app::registry().into_iter().map(|o| (o.name, o.run)).collect();
        Etat {
            pool,
            ops,
            badge,
            entrepot,
            hub: Arc::new(crate::direct::Hub::default()),
            limite_comptes: Limiteur::new(20, Duration::from_secs(60)),
            limite_renouvellement: Limiteur::new(120, Duration::from_secs(60)),
            limite_par_compte: Limiteur::new(10, Duration::from_secs(60)),
            portier_local,
        }
    }
}

pub fn router(etat: Arc<Etat>) -> Router {
    Router::new()
        .route("/v1/sante", get(sante))
        .route("/v1/auth/inscription", post(auth::inscription))
        .route("/v1/auth/connexion", post(auth::connexion))
        .route("/v1/auth/renouveler", post(auth::renouveler))
        .route("/v1/auth/deconnexion", post(auth::deconnexion))
        .route("/v1/auth/moi", get(auth::moi))
        .route("/v1/rpc/{nom}", post(rpc))
        .route("/v1/direct", get(crate::direct::ouvrir))
        .with_state(etat)
}

/// Une erreur devenue réponse HTTP.
pub struct ErreurHttp(pub NvError);

impl IntoResponse for ErreurHttp {
    fn into_response(self) -> Response {
        if !self.0.is_refusal() {
            tracing::error!("{}", self.0);
        }
        let status = StatusCode::from_u16(self.0.status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        (status, Json(self.0.body())).into_response()
    }
}

impl From<NvError> for ErreurHttp {
    fn from(e: NvError) -> Self {
        ErreurHttp(e)
    }
}

async fn sante(State(etat): State<Arc<Etat>>) -> Result<&'static str, ErreurHttp> {
    sqlx::query("select 1").execute(&etat.pool).await.map_err(NvError::from)?;
    Ok("ok")
}

/// `POST /v1/rpc/{nom}` : une opération du registre, dans sa transaction.
///
/// La transaction n'est validée que si l'opération réussit ; ce qui doit
/// suivre la validation (fichiers à effacer…) n'est fait qu'ensuite.
async fn rpc(
    State(etat): State<Arc<Etat>>,
    Path(nom): Path<String>,
    entetes: HeaderMap,
    body: Option<Json<Value>>,
) -> Result<Json<Value>, ErreurHttp> {
    let run = *etat.ops.get(nom.as_str()).ok_or_else(|| NvError::UnknownOp(nom.clone()))?;
    let (actor, _) = auth::appelant(&etat, &entetes)?;
    let tx = etat.pool.begin().await.map_err(NvError::from)?;
    let mut ctx = Ctx::open(tx, actor, Some(etat.entrepot.clone())).await?;
    let args = body.map(|Json(v)| v).unwrap_or(Value::Null);
    let resultat = run(&mut ctx, args).await?;
    let apres = std::mem::take(&mut ctx.after_commit);
    ctx.tx.commit().await.map_err(NvError::from)?;
    apres_validation(&etat, apres).await;
    Ok(Json(resultat))
}

/// Ce qui suit la validation. Un échec ici ne défait pas l'opération (elle
/// est validée) : il est journalisé, et le balai des fichiers repassera.
async fn apres_validation(etat: &Etat, gestes: Vec<AfterCommit>) {
    for g in gestes {
        match g {
            AfterCommit::DeleteFiles { bucket, paths } => {
                if let Err(e) = etat.entrepot.supprimer(&bucket, paths).await {
                    tracing::error!("suppression de fichiers ({bucket}) : {e}");
                }
            }
        }
    }
}
