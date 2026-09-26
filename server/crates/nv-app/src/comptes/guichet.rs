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
    profiles_get => profiles_get,
    profiles_list => profiles_list,
    profile_create => profile_create,
    profile_update => profile_update,
    dev_report_insert => dev_report_insert,
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

// ─── Les profils (l'app les lisait et écrivait directement dans la table) ──

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnProfil {
    p_id: Uuid,
}

/// `profiles_get(p_id)` : un profil que je peux voir, ou `null`
/// (ex-`from('profiles').select().eq('id', …).maybeSingle()`).
async fn profiles_get(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: UnProfil = parse(args)?;
    if !acces::can_view_profile(ctx.db(), moi, a.p_id).await? {
        return Ok(Value::Null);
    }
    let liste = cuisine::profils(ctx.db(), Some(moi), &[a.p_id]).await?;
    Ok(liste.as_array().and_then(|l| l.first()).cloned().unwrap_or(Value::Null))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DesProfils {
    p_ids: Vec<Uuid>,
}

/// `profiles_list(p_ids)` : ceux de ces profils que je peux voir
/// (ex-`from('profiles').select().inFilter('id', …)`).
async fn profiles_list(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: DesProfils = parse(args)?;
    let visibles = acces::profils_visibles(ctx.db(), moi, &a.p_ids).await?;
    cuisine::profils(ctx.db(), Some(moi), &visibles).await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Creation {
    id: Uuid,
    display_name: String,
    tag_name: Option<String>,
}

/// `profile_create` : crée MON profil (ex-`from('profiles').insert(…)`).
async fn profile_create(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Creation = parse(args)?;
    if a.id != moi {
        return Err(nv_core::NvError::refused("On ne crée que son propre profil."));
    }
    cuisine::creer_profil(ctx.db(), moi, &a.display_name, a.tag_name.as_deref()).await?;
    Ok(Value::Null)
}

/// `profile_update` : modifie des colonnes de MON profil
/// (ex-`from('profiles').update({…}).eq('id', moi)`).
///
/// Seules les colonnes que l'ancienne base ouvrait à l'app sont acceptées
/// (« une colonne modifiable est une décision », règle du 2026-09-25).
async fn profile_update(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    use cuisine::ValeurProfil as V;
    use nv_core::NvError;
    let moi = ctx.actor.uid()?;
    let Value::Object(champs) = args else { return Err(NvError::BadArgs("un objet est attendu".into())) };
    let mut colonnes: Vec<(&'static str, V)> = Vec::new();
    for (cle, v) in champs {
        let texte = |v: &Value| -> NvResult<Option<String>> {
            match v {
                Value::Null => Ok(None),
                Value::String(s) => Ok(Some(s.clone())),
                _ => Err(NvError::BadArgs(format!("{cle} : texte attendu"))),
            }
        };
        let booleen = |v: &Value| -> NvResult<bool> {
            v.as_bool().ok_or_else(|| NvError::BadArgs(format!("{cle} : vrai ou faux attendu")))
        };
        let (col, val): (&'static str, V) = match cle.as_str() {
            "display_name" => ("display_name", V::Texte(texte(&v)?)),
            "tag_name" => ("tag_name", V::Texte(texte(&v)?)),
            "bio" => ("bio", V::Texte(texte(&v)?)),
            "avatar_url" => ("avatar_url", V::Texte(texte(&v)?)),
            "special_mention" => ("special_mention", V::Texte(texte(&v)?)),
            "library_visibility" => (
                "library_visibility",
                V::Visibilite(texte(&v)?.ok_or_else(|| NvError::BadArgs("library_visibility : valeur attendue".into()))?),
            ),
            "show_pseudo" => ("show_pseudo", V::Booleen(booleen(&v)?)),
            "special_mention_public" => ("special_mention_public", V::Booleen(booleen(&v)?)),
            "realtime_waves" => ("realtime_waves", V::Booleen(booleen(&v)?)),
            "stories_public" => ("stories_public", V::Booleen(booleen(&v)?)),
            autre => return Err(NvError::BadArgs(format!("colonne non modifiable : {autre}"))),
        };
        colonnes.push((col, val));
    }
    cuisine::modifier_profil(ctx.db(), moi, &colonnes).await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rapport {
    author_id: Uuid,
    kind: String,
    app_version: Option<String>,
    device: Option<String>,
    note: Option<String>,
    body: Option<String>,
    data: Option<Value>,
}

/// `dev_report_insert` : un rapport de diagnostic (outil de développement,
/// à retirer avant la production avec l'écran qui l'écrit).
async fn dev_report_insert(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Rapport = parse(args)?;
    if a.author_id != moi {
        return Err(nv_core::NvError::refused("On ne dépose que ses propres rapports."));
    }
    cuisine::deposer_rapport(
        ctx.db(),
        moi,
        &a.kind,
        a.app_version.as_deref(),
        a.device.as_deref(),
        a.note.as_deref(),
        a.body.as_deref(),
        a.data.as_ref(),
    )
    .await?;
    Ok(Value::Null)
}
