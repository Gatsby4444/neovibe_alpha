//! Les balais présentés comme des opérations — **pour la preuve seulement**.
//!
//! Le guichet HTTP ne les expose pas : ils ne sont pas dans
//! [`crate::registry`]. Le serveur les lance lui-même, à leur rythme
//! (`nv-server/src/taches.rs`) ; la preuve les joue ici, dans la même
//! transaction que l'ancien balai SQL, pour comparer ce qu'ils écrivent.
use serde_json::Value;

use nv_core::{ops, Ctx, NvResult};

ops![
    balai_soirees => balai_soirees,
    balai_rencontres => balai_rencontres,
    balai_drop => balai_drop,
    balai_retraits => balai_retraits,
    balai_general => balai_general,
    balai_canaux => balai_canaux,
    balai_ping => balai_ping,
    balai_vues => balai_vues,
    balai_positions => balai_positions,
    balai_demandes => balai_demandes,
];

async fn balai_soirees(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::soirees::balai::balayer(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_rencontres(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::soirees::balai::oublier_les_rencontres(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_drop(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::vibes::balai_drop(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_retraits(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::vibes::balai_retraits(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_general(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::conversations::balai_general(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_canaux(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::conversations::balai_canaux(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_ping(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::relations::balai_ping(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_vues(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::relations::balai_vues(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_positions(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::carte::balai_positions(ctx.db()).await.map(|_| Value::Null)
}

async fn balai_demandes(ctx: &mut Ctx, _: Value) -> NvResult<Value> {
    crate::carte::balai_demandes(ctx.db()).await.map(|_| Value::Null)
}
