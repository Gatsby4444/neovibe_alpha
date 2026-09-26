//! Les règles des coffres de fichiers — traduction des 24 politiques de
//! l'ancien stockage (`storage.objects`), coffre par coffre.
//!
//! Les chemins suivent la convention de l'app : `<compte>/…`. Le premier
//! dossier désigne le propriétaire ; les affiches de soirée ajoutent la
//! soirée en second dossier (`<compte>/<soirée>/poster_….jpg`).
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

use crate::acces::{q, vrai, P};

/// Les coffres.
pub const COFFRES: [&str; 7] = ["avatars", "cards", "event_posters", "library", "library_vault", "media", "stories"];

/// Taille maximale d'un fichier : 50 Mo partout (la limite de l'ancien
/// stockage, que l'app respecte déjà), 3 Mo pour une affiche de soirée.
pub fn taille_max(coffre: &str) -> u64 {
    if coffre == "event_posters" { 3 * 1024 * 1024 } else { 50 * 1024 * 1024 }
}

/// Les types acceptés, quand un coffre les restreint.
pub fn type_accepte(coffre: &str, type_: &str) -> bool {
    coffre != "event_posters" || type_ == "image/jpeg"
}

/// `(storage.foldername(nom))[1]` : le premier dossier d'un chemin, s'il y
/// a au moins un dossier.
pub fn premier_dossier(chemin: &str) -> Option<&str> {
    let mut parts = chemin.split('/');
    let premier = parts.next()?;
    parts.next().map(|_| premier)
}

/// `private.poster_event(nom)` : la soirée d'une affiche (second dossier).
pub fn soiree_de_l_affiche(chemin: &str) -> Option<Uuid> {
    let parts: Vec<&str> = chemin.split('/').collect();
    if parts.len() >= 3 { Uuid::parse_str(parts[1]).ok() } else { None }
}

fn a_moi(chemin: &str, moi: Uuid) -> bool {
    premier_dossier(chemin) == Some(moi.to_string().as_str())
}

/// Déposer : dans son propre dossier ; une affiche, seulement pour une
/// soirée qu'on organise et qui est ouverte.
pub async fn peut_deposer(db: &mut PgConnection, moi: Uuid, coffre: &str, chemin: &str) -> NvResult<bool> {
    if !COFFRES.contains(&coffre) || !a_moi(chemin, moi) {
        return Ok(false);
    }
    if coffre == "event_posters" {
        let Some(soiree) = soiree_de_l_affiche(chemin) else { return Ok(false) };
        return vrai(db, &q::gere_evenement_ouvert("$1::uuid", "$2::uuid"), &[P::U(soiree), P::U(moi)]).await;
    }
    Ok(true)
}

/// Supprimer : dans son propre dossier, et jamais un fichier retenu par la
/// modération (sauf les photos de profil et les pièces du chat, que
/// l'ancienne règle ne retenait pas).
pub async fn peut_supprimer(db: &mut PgConnection, moi: Uuid, coffre: &str, chemin: &str) -> NvResult<bool> {
    if !COFFRES.contains(&coffre) || !a_moi(chemin, moi) {
        return Ok(false);
    }
    if coffre == "avatars" || coffre == "media" {
        return Ok(true);
    }
    Ok(!vrai(db, &q::retenu("$1::text", "$2::text"), &[P::T(coffre.into()), P::T(chemin.into())]).await?)
}

/// Lire.
pub async fn peut_lire(db: &mut PgConnection, moi: Uuid, coffre: &str, chemin: &str) -> NvResult<bool> {
    if !COFFRES.contains(&coffre) {
        return Ok(false);
    }
    let (b, c, u) = (P::T(coffre.into()), P::T(chemin.into()), P::U(moi));
    // La preuve d'un signalement : lisible par un administrateur.
    let admin = format!("({} and {})", q::est_admin("$3::uuid"), q::retenu("$1::text", "$2::text"));
    if vrai(db, &admin, &[b.clone(), c.clone(), u.clone()]).await? {
        return Ok(true);
    }
    if a_moi(chemin, moi) && coffre != "event_posters" && coffre != "library_vault" && coffre != "avatars" {
        return Ok(true);
    }
    let regle = match coffre {
        "avatars" => {
            let Some(proprio) = premier_dossier(chemin).and_then(|p| Uuid::parse_str(p).ok()) else {
                return Ok(false);
            };
            return vrai(db, &q::peut_voir_profil("$1::uuid", "$2::uuid"), &[u, P::U(proprio)]).await;
        }
        "cards" => q::peut_voir_fichier_carte("$2::text", "$3::uuid"),
        "library" => q::peut_voir_fichier_publication("$2::text", "$3::uuid"),
        "stories" => q::peut_voir_fichier_story("$2::text", "$3::uuid"),
        "event_posters" => format!(
            "exists (select 1 from public.events fp_e where fp_e.poster_path = $2::text and {})",
            q::peut_voir_evenement("fp_e.id", "$3::uuid")
        ),
        "library_vault" => "(exists (select 1 from public.library_vibes fv_v join public.conversation_members fv_m \
             on fv_m.conversation_id = fv_v.conversation_id and fv_m.user_id = $3::uuid \
             where $2::text in (fv_v.placeholder_path, fv_v.placeholder_back_path)) \
             or exists (select 1 from public.library_vibes fv_s join public.conversation_members fv_sm \
             on fv_sm.conversation_id = fv_s.conversation_id and fv_sm.user_id = $3::uuid \
             where $2::text in (fv_s.sealed_path, fv_s.sealed_back_path) and now() >= fv_s.reveal_at - interval '5 minutes'))"
            .to_string(),
        "media" => format!(
            "exists (select 1 from public.messages fm_ where fm_.media_path = $2::text and fm_.expires_at > now() and {})",
            q::membre_conversation("fm_.conversation_id", "$3::uuid")
        ),
        _ => return Ok(false),
    };
    // `$1` (le coffre) n'est pas cité par toutes les règles : on le lie
    // quand même, typé, pour garder la même numérotation.
    vrai(db, &format!("($1::text is not null and {regle})"), &[b, c, u]).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_dossiers_d_un_chemin() {
        assert_eq!(premier_dossier("a/b/c.jpg"), Some("a"));
        assert_eq!(premier_dossier("a/"), Some("a"));
        assert_eq!(premier_dossier("fichier.jpg"), None);
        assert_eq!(premier_dossier(""), None);
        let s = Uuid::new_v4();
        assert_eq!(soiree_de_l_affiche(&format!("moi/{s}/poster_1.jpg")), Some(s));
        assert_eq!(soiree_de_l_affiche("moi/pas-un-uuid/poster.jpg"), None);
        assert_eq!(soiree_de_l_affiche("moi/poster.jpg"), None);
    }

    #[test]
    fn les_limites() {
        assert_eq!(taille_max("event_posters"), 3 * 1024 * 1024);
        assert_eq!(taille_max("library"), 50 * 1024 * 1024);
        assert!(type_accepte("event_posters", "image/jpeg"));
        assert!(!type_accepte("event_posters", "image/png"));
        assert!(type_accepte("avatars", "image/png"));
    }
}
