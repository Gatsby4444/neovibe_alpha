//! Les guichets des comptes et des profils.
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvResult};

use super::{cuisine, gardien};
use crate::acces;

ops![
    username_available => username_available,
    my_suspension => my_suspension,
    profile_stats => profile_stats,
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UsernameArgs {
    p_username: Option<String>,
}

/// `username_available(p_username)` : le nom est bien formé et libre.
///
/// Ouvert SANS compte : l'arrivée le demande pendant que la personne tape
/// son nom, avant que le compte existe (`arrival_flow.dart`, `_check`).
async fn username_available(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: UsernameArgs = parse(args)?;
    // Un nom absent laisse l'ancienne expression SQL indéterminée : `null`.
    let Some(nom) = a.p_username else { return Ok(Value::Null) };
    if !gardien::username_bien_forme(&nom) {
        return Ok(json!(false));
    }
    Ok(json!(!cuisine::username_pris(ctx.db(), &nom).await?))
}

/// `my_suspension()` : ma suspension, s'il y en a une.
async fn my_suspension(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    cuisine::ma_suspension(ctx.db(), moi).await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProfileStatsArgs {
    target: Option<Uuid>,
}

/// `profile_stats(target)` : les chiffres d'un profil que je peux voir.
async fn profile_stats(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: ProfileStatsArgs = parse(args)?;
    let Some(cible) = a.target else { return Ok(json!([])) };
    if moi != cible && !acces::can_view_profile(ctx.db(), moi, cible).await? {
        return Ok(json!([]));
    }
    cuisine::chiffres_du_profil(ctx.db(), cible).await
}
