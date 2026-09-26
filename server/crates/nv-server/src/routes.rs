//! Les routes HTTP : le guichet commun à tous les domaines.
use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::Value;
use sqlx::PgPool;

use nv_core::ops::OpFn;
use nv_core::{Actor, Ctx, NvError};

/// L'état partagé par les routes.
pub struct Etat {
    pub pool: PgPool,
    pub ops: HashMap<&'static str, OpFn>,
}

impl Etat {
    pub fn new(pool: PgPool) -> Self {
        let ops = nv_app::registry().into_iter().map(|o| (o.name, o.run)).collect();
        Etat { pool, ops }
    }
}

pub fn router(etat: Arc<Etat>) -> Router {
    Router::new()
        .route("/v1/sante", get(sante))
        .route("/v1/rpc/{nom}", post(rpc))
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
    body: Option<Json<Value>>,
) -> Result<Json<Value>, ErreurHttp> {
    let run = *etat.ops.get(nom.as_str()).ok_or_else(|| NvError::UnknownOp(nom.clone()))?;
    let actor = Actor::Anonymous; // le badge arrive à l'étape 1 (les comptes)
    let tx = etat.pool.begin().await.map_err(NvError::from)?;
    let mut ctx = Ctx::open(tx, actor).await?;
    let args = body.map(|Json(v)| v).unwrap_or(Value::Null);
    let resultat = run(&mut ctx, args).await?;
    ctx.tx.commit().await.map_err(NvError::from)?;
    Ok(Json(resultat))
}
