//! Les guichets des fichiers.
//!
//! | Opération | Ce qu'elle remplace |
//! |---|---|
//! | `files_sign_read` | `createSignedUrl(s)` et `download` (le téléphone lit ensuite le lien) |
//! | `files_sign_upload` | `upload` / `uploadBinary` (le téléphone dépose ensuite au lien) |
//! | `files_remove` | `remove` |
//! | `files_upload_open · parts · part_url · finish · abort` | l'envoi reprenable (TUS) de la file de publication native |
//! | `mes_octets_a_supprimer`, `octets_supprimes` | les mêmes fonctions SQL (le ménage fait par l'app) |
use serde::Deserialize;
use serde_json::{json, Value};

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, AfterCommit, Ctx, NvError, NvResult};

use super::regles;

ops![
    files_sign_read => files_sign_read,
    files_sign_upload => files_sign_upload,
    files_remove => files_remove,
    files_upload_open => files_upload_open,
    files_upload_parts => files_upload_parts,
    files_upload_part_url => files_upload_part_url,
    files_upload_finish => files_upload_finish,
    files_upload_abort => files_upload_abort,
    mes_octets_a_supprimer => mes_octets_a_supprimer,
    octets_supprimes => octets_supprimes,
];

/// Durée d'un lien de lecture : celle demandée, entre 1 minute et 7 jours.
fn duree(demandee: Option<u64>) -> u64 {
    demandee.unwrap_or(3600).clamp(60, 7 * 24 * 3600)
}

/// Durée d'un lien de dépôt : 15 minutes.
const DUREE_DEPOT_S: u64 = 900;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Lecture {
    bucket: String,
    paths: Vec<String>,
    expires_in: Option<u64>,
}

/// `files_sign_read` : un lien de lecture par chemin que j'ai le droit de
/// lire ; `null` (et l'erreur) pour les autres — comme `createSignedUrls`.
async fn files_sign_read(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Lecture = parse(args)?;
    let entrepot = ctx.entrepot()?;
    let mut sortie = Vec::with_capacity(a.paths.len());
    for chemin in a.paths {
        if regles::peut_lire(ctx.db(), moi, &a.bucket, &chemin).await? {
            let lien = entrepot.lien_lecture(&a.bucket, &chemin, duree(a.expires_in))?;
            sortie.push(json!({ "path": chemin, "signedUrl": lien, "error": null }));
        } else {
            sortie.push(json!({ "path": chemin, "signedUrl": null, "error": "Fichier introuvable ou non autorisé" }));
        }
    }
    Ok(Value::Array(sortie))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Depot {
    bucket: String,
    path: String,
    content_type: String,
    size: u64,
    #[serde(default)]
    upsert: bool,
}

fn verifier_taille_type(coffre: &str, type_: &str, taille: u64) -> NvResult<()> {
    if taille > regles::taille_max(coffre) {
        return Err(NvError::refused("Fichier trop lourd."));
    }
    if !regles::type_accepte(coffre, type_) {
        return Err(NvError::refused("Type de fichier refusé."));
    }
    Ok(())
}

/// `files_sign_upload` : un lien pour déposer un fichier entier, dans un
/// coffre et un chemin où j'ai le droit d'écrire.
async fn files_sign_upload(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Depot = parse(args)?;
    if !regles::peut_deposer(ctx.db(), moi, &a.bucket, &a.path).await? {
        return Err(NvError::refused("Dépôt refusé : ce chemin ne t'appartient pas."));
    }
    verifier_taille_type(&a.bucket, &a.content_type, a.size)?;
    let entrepot = ctx.entrepot()?;
    if !a.upsert && entrepot.taille(&a.bucket, &a.path).await?.is_some() {
        return Err(NvError::refused("Ce fichier existe déjà."));
    }
    let lien = entrepot.lien_depot(&a.bucket, &a.path, &a.content_type, a.size, DUREE_DEPOT_S)?;
    Ok(json!({
        "url": lien,
        "method": "PUT",
        "headers": { "content-type": a.content_type, "content-length": a.size.to_string() },
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Retrait {
    bucket: String,
    paths: Vec<String>,
}

/// `files_remove` : supprime ceux des fichiers que j'ai le droit de
/// supprimer (les autres sont ignorés, comme avant). L'effacement a lieu
/// APRÈS la validation.
async fn files_remove(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Retrait = parse(args)?;
    let mut ok = Vec::new();
    for chemin in a.paths {
        if regles::peut_supprimer(ctx.db(), moi, &a.bucket, &chemin).await? {
            ok.push(chemin);
        }
    }
    if !ok.is_empty() {
        ctx.after_commit.push(AfterCommit::DeleteFiles { bucket: a.bucket.clone(), paths: ok.clone() });
    }
    Ok(Value::Array(ok.into_iter().map(|n| json!({ "name": n })).collect()))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ouverture {
    bucket: String,
    path: String,
    size: u64,
    content_type: String,
}

/// `files_upload_open` : ouvre un envoi en morceaux (la file de publication
/// native), après les mêmes vérifications qu'un dépôt.
async fn files_upload_open(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Ouverture = parse(args)?;
    if !regles::peut_deposer(ctx.db(), moi, &a.bucket, &a.path).await? {
        return Err(NvError::refused("Dépôt refusé : ce chemin ne t'appartient pas."));
    }
    verifier_taille_type(&a.bucket, &a.content_type, a.size)?;
    let envoi = ctx.entrepot()?.ouvrir_envoi(&a.bucket, &a.path, &a.content_type).await?;
    Ok(json!({ "upload_id": envoi }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envoi {
    bucket: String,
    path: String,
    upload_id: String,
}

async fn verifier_envoi(ctx: &mut Ctx, a: &Envoi) -> NvResult<()> {
    let moi = ctx.actor.uid()?;
    if !regles::peut_deposer(ctx.db(), moi, &a.bucket, &a.path).await? {
        return Err(NvError::refused("Dépôt refusé : ce chemin ne t'appartient pas."));
    }
    Ok(())
}

/// `files_upload_parts` : ce que l'entrepôt a déjà reçu (pour reprendre
/// après une coupure) ; `known = false` si l'envoi n'existe plus.
async fn files_upload_parts(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Envoi = parse(args)?;
    verifier_envoi(ctx, &a).await?;
    Ok(match ctx.entrepot()?.morceaux(&a.bucket, &a.path, &a.upload_id).await? {
        None => json!({ "known": false, "parts": [] }),
        Some(m) => json!({
            "known": true,
            "parts": m.iter().map(|p| json!({ "number": p.numero, "size": p.taille })).collect::<Vec<_>>(),
        }),
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnMorceau {
    bucket: String,
    path: String,
    upload_id: String,
    part_number: u16,
}

/// `files_upload_part_url` : le lien pour déposer un morceau.
async fn files_upload_part_url(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: UnMorceau = parse(args)?;
    let e = Envoi { bucket: a.bucket, path: a.path, upload_id: a.upload_id };
    verifier_envoi(ctx, &e).await?;
    if a.part_number == 0 || a.part_number > 10_000 {
        return Err(NvError::BadArgs("numéro de morceau hors limites".into()));
    }
    let lien = ctx.entrepot()?.lien_morceau(&e.bucket, &e.path, &e.upload_id, a.part_number, DUREE_DEPOT_S)?;
    Ok(json!({ "url": lien }))
}

/// `files_upload_finish` : assemble les morceaux reçus — s'ils se suivent
/// sans trou et ne dépassent pas la taille permise.
async fn files_upload_finish(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Envoi = parse(args)?;
    verifier_envoi(ctx, &a).await?;
    let entrepot = ctx.entrepot()?;
    let morceaux = entrepot
        .morceaux(&a.bucket, &a.path, &a.upload_id)
        .await?
        .ok_or_else(|| NvError::refused("Cet envoi n'existe plus : recommence-le."))?;
    let suivis = morceaux.iter().enumerate().all(|(i, m)| m.numero as usize == i + 1);
    if morceaux.is_empty() || !suivis {
        return Err(NvError::refused("Envoi incomplet : des morceaux manquent."));
    }
    let total: u64 = morceaux.iter().map(|m| m.taille).sum();
    if total > regles::taille_max(&a.bucket) {
        entrepot.abandonner_envoi(&a.bucket, &a.path, &a.upload_id).await?;
        return Err(NvError::refused("Fichier trop lourd."));
    }
    entrepot.terminer_envoi(&a.bucket, &a.path, &a.upload_id, morceaux).await?;
    Ok(json!({ "size": total }))
}

/// `files_upload_abort` : abandonne un envoi.
async fn files_upload_abort(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let a: Envoi = parse(args)?;
    verifier_envoi(ctx, &a).await?;
    ctx.entrepot()?.abandonner_envoi(&a.bucket, &a.path, &a.upload_id).await?;
    Ok(Value::Null)
}

/// `mes_octets_a_supprimer()` : mes fichiers dont le délai de grâce est
/// passé (200 au plus), hors fichiers retenus par la modération.
async fn mes_octets_a_supprimer(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t), '[]'::json) as "j!" from (
             select t.bucket_id, t.object_name from public.storage_tombstones t
              where t.owner_id = $1 and t.delete_after <= now()
                and not exists (select 1 from public.moderation_holds h
                                 where h.bucket_id = t.bucket_id and h.object_name = t.object_name)
              order by t.delete_after limit 200) t"#,
        moi
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Supprimes {
    p_bucket: String,
    p_names: Vec<String>,
}

/// `octets_supprimes(p_bucket, p_names)` : l'app confirme l'effacement ;
/// les pierres tombales correspondantes disparaissent.
async fn octets_supprimes(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Supprimes = parse(args)?;
    let n = sqlx::query!(
        "delete from public.storage_tombstones t
          where t.owner_id = $1 and t.bucket_id = $2 and t.object_name = any($3)",
        moi,
        a.p_bucket,
        &a.p_names
    )
    .execute(ctx.db())
    .await?
    .rows_affected();
    Ok(json!(n))
}
