//! La connexion : inscription, connexion, renouvellement, déconnexion.
//!
//! Remplace le service de connexion de Supabase, avec les mêmes règles
//! (relevées le 2026-09-26 dans sa configuration) :
//! - pas de mail à confirmer (`mailer_autoconfirm`) ;
//! - mot de passe de 6 caractères au moins (`password_min_length`) ;
//! - **le plafond de comptes par téléphone** (ex-`hook_before_user_created`)
//!   et son registre (ex-`record_device_signup`) ;
//! - jetons de renouvellement **tournants** : un jeton réutilisé au-delà de
//!   10 s révoque toute la session (`security_refresh_token_reuse_interval`).
//!
//! Les mots de passe sont vérifiés et stockés par des bibliothèques
//! éprouvées : `argon2id` pour les nouveaux ; l'empreinte `bcrypt` des
//! comptes venus de Supabase est acceptée, puis réécrite en argon2id.
use std::sync::OnceLock;

use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use base64::Engine;
use rand::RngCore;
use serde::Serialize;
use sha2::{Digest, Sha256};
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::{NvError, NvResult};

use super::badge::{Badge, DUREE_BADGE_S};

/// Délai de grâce d'un jeton de renouvellement déjà utilisé (deux
/// renouvellements presque simultanés — l'app et son service natif — ne sont
/// pas un vol).
pub const GRACE_REUTILISATION_S: i64 = 10;
const MOT_DE_PASSE_MIN: usize = 6;

/// Ce que reçoit l'app après une connexion réussie.
#[derive(Debug, Serialize)]
pub struct Jetons {
    pub access_token: String,
    pub token_type: &'static str,
    pub expires_in: u64,
    pub expires_at: i64,
    pub refresh_token: String,
    pub user: Utilisateur,
}

#[derive(Debug, Serialize)]
pub struct Utilisateur {
    pub id: Uuid,
    pub email: String,
}

// ─── Règles pures ────────────────────────────────────────────────────────────

/// Une adresse mail acceptable (la forme, pas l'existence), mise en
/// minuscules.
pub fn adresse_normalisee(brute: &str) -> NvResult<String> {
    let a = brute.trim().to_lowercase();
    let valide = a.len() <= 254
        && a.split_once('@').is_some_and(|(avant, apres)| {
            !avant.is_empty() && apres.contains('.') && !apres.starts_with('.') && !apres.ends_with('.')
        })
        && !a.chars().any(char::is_whitespace);
    if valide { Ok(a) } else { Err(NvError::refused("Adresse mail invalide.")) }
}

/// Un mot de passe assez long.
pub fn mot_de_passe_acceptable(mdp: &str) -> NvResult<()> {
    if mdp.chars().count() < MOT_DE_PASSE_MIN {
        return Err(NvError::refused("Le mot de passe doit contenir au moins 6 caractères."));
    }
    Ok(())
}

/// L'empreinte du téléphone a la bonne forme (64 caractères hexadécimaux).
pub fn empreinte_valide(e: Option<&str>) -> bool {
    e.is_some_and(|h| h.len() == 64 && h.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)))
}

fn empreinte_jeton(jeton: &str) -> String {
    hex::encode(Sha256::digest(jeton.as_bytes()))
}

fn nouveau_jeton() -> String {
    let mut octets = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut octets);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(octets)
}

fn hacher(mdp: &str) -> NvResult<String> {
    let sel = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(mdp.as_bytes(), &sel)
        .map(|h| h.to_string())
        .map_err(|e| NvError::Internal(format!("argon2 : {e}")))
}

/// Vérifie un mot de passe contre une empreinte argon2id ou bcrypt.
fn verifier_mdp(mdp: &str, empreinte: &str) -> bool {
    if empreinte.starts_with("$argon2") {
        PasswordHash::new(empreinte)
            .map(|h| Argon2::default().verify_password(mdp.as_bytes(), &h).is_ok())
            .unwrap_or(false)
    } else if empreinte.starts_with("$2") {
        bcrypt::verify(mdp, empreinte).unwrap_or(false)
    } else {
        false
    }
}

/// Une empreinte factice : vérifiée quand l'adresse est inconnue, pour que
/// la réponse prenne le même temps (ne pas révéler quels comptes existent).
fn empreinte_factice() -> &'static str {
    static F: OnceLock<String> = OnceLock::new();
    F.get_or_init(|| hacher("mot de passe factice").unwrap_or_default())
}

// ─── Les gestes ─────────────────────────────────────────────────────────────

async fn ouvrir_session(
    db: &mut PgConnection,
    badge: &Badge,
    compte: Uuid,
    email: String,
    appareil: Option<&str>,
) -> NvResult<Jetons> {
    let session: Uuid = sqlx::query_scalar!(
        "insert into nv.sessions (user_id, user_agent) values ($1, $2) returning id",
        compte,
        appareil
    )
    .fetch_one(&mut *db)
    .await?;
    let jeton = nouveau_jeton();
    sqlx::query!(
        "insert into nv.refresh_tokens (hash, session_id) values ($1, $2)",
        empreinte_jeton(&jeton),
        session
    )
    .execute(&mut *db)
    .await?;
    let (access_token, expires_at) = badge.emettre(compte, session)?;
    Ok(Jetons {
        access_token,
        token_type: "bearer",
        expires_in: DUREE_BADGE_S,
        expires_at,
        refresh_token: jeton,
        user: Utilisateur { id: compte, email },
    })
}

/// **Le plafond de comptes par téléphone** (ex-`hook_before_user_created`,
/// mêmes messages) : 3 comptes au plus par téléphone sur 30 jours
/// (`private.signup_rules`), sauf téléphone exempté.
pub async fn plafond_du_telephone(db: &mut PgConnection, empreinte: Option<&str>) -> NvResult<()> {
    if !empreinte_valide(empreinte) {
        return Err(NvError::refused("Mets NeoVibe à jour pour créer un compte."));
    }
    let empreinte = empreinte.unwrap_or_default();
    let exempte = sqlx::query_scalar!(
        r#"select exists (select 1 from private.signup_device_exempt where device_hash = $1) as "b!""#,
        empreinte
    )
    .fetch_one(&mut *db)
    .await?;
    if exempte {
        return Ok(());
    }
    let trop = sqlx::query_scalar!(
        r#"select (select count(*) from private.device_signups s
                    where s.device_hash = $1
                      and s.created_at > now() - r.per_window) >= r.max_accounts as "b!"
             from private.signup_rules r"#,
        empreinte
    )
    .fetch_one(&mut *db)
    .await?;
    if trop {
        return Err(NvError::refused("Ce téléphone a déjà créé trop de comptes récemment."));
    }
    Ok(())
}

/// **Inscription.** Le plafond par téléphone, puis le compte, puis la
/// session.
pub async fn inscrire(
    db: &mut PgConnection,
    badge: &Badge,
    email: &str,
    mdp: &str,
    empreinte: Option<&str>,
    appareil: Option<&str>,
) -> NvResult<Jetons> {
    let email = adresse_normalisee(email)?;
    mot_de_passe_acceptable(mdp)?;
    plafond_du_telephone(db, empreinte).await?;
    let empreinte = empreinte.unwrap_or_default();
    let existe = sqlx::query_scalar!(
        r#"select exists (select 1 from auth.users where lower(email) = $1) as "b!""#,
        email
    )
    .fetch_one(&mut *db)
    .await?;
    if existe {
        return Err(NvError::refused("Un compte existe déjà avec cette adresse."));
    }
    let empreinte_mdp = hacher(mdp)?;
    let compte: Uuid = sqlx::query_scalar!(
        r#"insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                                   email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                   created_at, updated_at, is_sso_user, is_anonymous)
           values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
                   'authenticated', $1, $2, now(),
                   '{"provider":"email","providers":["email"]}'::jsonb,
                   jsonb_build_object('device_hash', $3::text), now(), now(), false, false)
           returning id"#,
        email,
        empreinte_mdp,
        empreinte
    )
    .fetch_one(&mut *db)
    .await?;
    // Le registre du plafond (ex-déclencheur `record_device_signup`).
    sqlx::query!(
        "insert into private.device_signups (user_id, device_hash) values ($1, $2)
         on conflict (user_id) do nothing",
        compte,
        empreinte
    )
    .execute(&mut *db)
    .await?;
    ouvrir_session(db, badge, compte, email, appareil).await
}

/// **Connexion** par adresse et mot de passe.
pub async fn connecter(
    db: &mut PgConnection,
    badge: &Badge,
    email: &str,
    mdp: &str,
    appareil: Option<&str>,
) -> NvResult<Jetons> {
    let refus = || NvError::refused("Adresse ou mot de passe incorrect.");
    let email = adresse_normalisee(email).map_err(|_| refus())?;
    let ligne = sqlx::query!(
        r#"select id, coalesce(encrypted_password, '') as "mdp!", deleted_at,
                  coalesce(banned_until > now(), false) as "banni!"
             from auth.users where lower(email) = $1"#,
        email
    )
    .fetch_optional(&mut *db)
    .await?;
    let Some(u) = ligne else {
        let _ = verifier_mdp(mdp, empreinte_factice());
        return Err(refus());
    };
    if !verifier_mdp(mdp, &u.mdp) || u.deleted_at.is_some() {
        return Err(refus());
    }
    if u.banni {
        return Err(NvError::refused("Ce compte est bloqué."));
    }
    // Une empreinte venue de Supabase (bcrypt) passe en argon2id.
    let nouvelle = if u.mdp.starts_with("$2") { Some(hacher(mdp)?) } else { None };
    sqlx::query!(
        "update auth.users set last_sign_in_at = now(), updated_at = now(),
                encrypted_password = coalesce($2, encrypted_password)
          where id = $1",
        u.id,
        nouvelle
    )
    .execute(&mut *db)
    .await?;
    ouvrir_session(db, badge, u.id, email, appareil).await
}

/// **Renouvellement** : un jeton de renouvellement contre un nouveau badge
/// et un nouveau jeton.
pub async fn renouveler(db: &mut PgConnection, badge: &Badge, jeton: &str) -> NvResult<Jetons> {
    let ligne = sqlx::query!(
        r#"select t.session_id, t.used_at is not null as "utilise!",
                  coalesce(now() - t.used_at > make_interval(secs => $2), false) as "trop_tard!",
                  s.user_id, s.revoked_at, coalesce(u.email, '') as "email!"
             from nv.refresh_tokens t
             join nv.sessions s on s.id = t.session_id
             join auth.users u on u.id = s.user_id
            where t.hash = $1
            for update of t"#,
        empreinte_jeton(jeton),
        GRACE_REUTILISATION_S as f64
    )
    .fetch_optional(&mut *db)
    .await?;
    let Some(l) = ligne else { return Err(NvError::Unauthenticated) };
    if l.revoked_at.is_some() {
        return Err(NvError::Unauthenticated);
    }
    if l.utilise {
        if l.trop_tard {
            // Réutilisé trop tard : quelqu'un d'autre a ce jeton.
            sqlx::query!("update nv.sessions set revoked_at = now() where id = $1", l.session_id)
                .execute(&mut *db)
                .await?;
            return Err(NvError::Unauthenticated);
        }
    } else {
        sqlx::query!("update nv.refresh_tokens set used_at = now() where hash = $1", empreinte_jeton(jeton))
            .execute(&mut *db)
            .await?;
    }
    let suivant = nouveau_jeton();
    sqlx::query!(
        "insert into nv.refresh_tokens (hash, session_id) values ($1, $2)",
        empreinte_jeton(&suivant),
        l.session_id
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!("update nv.sessions set refreshed_at = now() where id = $1", l.session_id)
        .execute(&mut *db)
        .await?;
    let (access_token, expires_at) = badge.emettre(l.user_id, l.session_id)?;
    Ok(Jetons {
        access_token,
        token_type: "bearer",
        expires_in: DUREE_BADGE_S,
        expires_at,
        refresh_token: suivant,
        user: Utilisateur { id: l.user_id, email: l.email },
    })
}

/// **Déconnexion** : la session est révoquée, ses jetons ne renouvellent
/// plus rien. (Le badge en cours vit jusqu'à son expiration, 1 h au plus.)
pub async fn deconnecter(db: &mut PgConnection, session: Uuid) -> NvResult<()> {
    sqlx::query!("update nv.sessions set revoked_at = now() where id = $1 and revoked_at is null", session)
        .execute(db)
        .await?;
    Ok(())
}

/// L'adresse d'un compte (pour `GET /v1/auth/moi`).
pub async fn adresse_du_compte(db: &mut PgConnection, compte: Uuid) -> NvResult<Option<String>> {
    Ok(sqlx::query_scalar!("select email from auth.users where id = $1", compte)
        .fetch_optional(db)
        .await?
        .flatten())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_adresses() -> NvResult<()> {
        assert_eq!(adresse_normalisee("  Jay@Exemple.FR ")?, "jay@exemple.fr");
        assert!(adresse_normalisee("pas-une-adresse").is_err());
        assert!(adresse_normalisee("a@b").is_err());
        assert!(adresse_normalisee("@exemple.fr").is_err());
        assert!(adresse_normalisee("a b@exemple.fr").is_err());
        Ok(())
    }

    #[test]
    fn les_empreintes_de_telephone() {
        assert!(empreinte_valide(Some(&"a1".repeat(32))));
        assert!(!empreinte_valide(Some(&"A1".repeat(32))));
        assert!(!empreinte_valide(Some("abc")));
        assert!(!empreinte_valide(None));
    }

    #[test]
    fn les_mots_de_passe_argon2_et_bcrypt() -> NvResult<()> {
        let a = hacher("secret123")?;
        assert!(verifier_mdp("secret123", &a));
        assert!(!verifier_mdp("secret124", &a));
        let b = bcrypt::hash("secret123", 4).map_err(|e| NvError::Internal(e.to_string()))?;
        assert!(verifier_mdp("secret123", &b));
        assert!(!verifier_mdp("autre", &b));
        assert!(!verifier_mdp("secret123", "n'importe quoi"));
        Ok(())
    }
}
