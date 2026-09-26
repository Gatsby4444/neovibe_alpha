//! Le **badge** : le jeton qui prouve, à chaque demande, qui appelle.
//!
//! Un jeton signé (JWT, Ed25519) valable 1 h, comme celui de Supabase —
//! le natif de l'app s'appuie déjà sur cette durée (`SessionStore.kt`).
//! Il porte le compte (`sub`) et la session (`sid`). Aucune cryptographie
//! maison : la signature vient de `jwt-simple`.
use std::collections::HashSet;

use jwt_simple::prelude::*;
use uuid::Uuid;

use nv_core::{NvError, NvResult};

/// Durée de validité d'un badge, en secondes.
pub const DUREE_BADGE_S: u64 = 3600;
const AUDIENCE: &str = "neovibe";

#[derive(Serialize, Deserialize)]
struct Extra {
    sid: Uuid,
    role: String,
}

/// La clé qui signe et vérifie les badges.
pub struct Badge {
    paire: Ed25519KeyPair,
    publique: Ed25519PublicKey,
}

impl Badge {
    /// Depuis la paire de clés encodée (`NV_BADGE_CLE`, voir
    /// [`Badge::nouvelle_cle`]).
    pub fn depuis_octets(octets: &[u8]) -> NvResult<Self> {
        let paire = Ed25519KeyPair::from_bytes(octets)
            .map_err(|e| NvError::Internal(format!("clé du badge illisible : {e}")))?;
        let publique = paire.public_key();
        Ok(Badge { paire, publique })
    }

    /// Une clé tirée au hasard (développement : les badges ne survivent pas
    /// au redémarrage du serveur).
    pub fn ephemere() -> Self {
        let paire = Ed25519KeyPair::generate();
        let publique = paire.public_key();
        Badge { paire, publique }
    }

    /// Une nouvelle paire de clés, à ranger dans la configuration.
    pub fn nouvelle_cle() -> Vec<u8> {
        Ed25519KeyPair::generate().to_bytes()
    }

    /// Émet un badge ; renvoie le jeton et son heure d'expiration (secondes
    /// depuis 1970).
    pub fn emettre(&self, compte: Uuid, session: Uuid) -> NvResult<(String, i64)> {
        let claims = Claims::with_custom_claims(
            Extra { sid: session, role: "authenticated".into() },
            Duration::from_secs(DUREE_BADGE_S),
        )
        .with_subject(compte.to_string())
        .with_audience(AUDIENCE);
        let expire = claims.expires_at.map(|t| t.as_secs() as i64).unwrap_or(0);
        let jeton = self.paire.sign(claims).map_err(|e| NvError::Internal(format!("signature : {e}")))?;
        Ok((jeton, expire))
    }

    /// Vérifie un badge ; renvoie le compte et la session.
    pub fn verifier(&self, jeton: &str) -> NvResult<(Uuid, Uuid)> {
        let options = VerificationOptions {
            allowed_audiences: Some(HashSet::from_strings(&[AUDIENCE])),
            time_tolerance: Some(Duration::from_secs(5)),
            ..Default::default()
        };
        let claims = self
            .publique
            .verify_token::<Extra>(jeton, Some(options))
            .map_err(|_| NvError::Unauthenticated)?;
        let compte = claims
            .subject
            .as_deref()
            .and_then(|s| Uuid::parse_str(s).ok())
            .ok_or(NvError::Unauthenticated)?;
        Ok((compte, claims.custom.sid))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn un_badge_emis_se_verifie() -> NvResult<()> {
        let b = Badge::ephemere();
        let (c, s) = (Uuid::new_v4(), Uuid::new_v4());
        let (jeton, _) = b.emettre(c, s)?;
        assert_eq!(b.verifier(&jeton)?, (c, s));
        Ok(())
    }

    #[test]
    fn un_badge_d_une_autre_cle_est_refuse() -> NvResult<()> {
        let (jeton, _) = Badge::ephemere().emettre(Uuid::new_v4(), Uuid::new_v4())?;
        assert!(matches!(Badge::ephemere().verifier(&jeton), Err(NvError::Unauthenticated)));
        Ok(())
    }

    #[test]
    fn un_badge_altere_est_refuse() -> NvResult<()> {
        let b = Badge::ephemere();
        let (mut jeton, _) = b.emettre(Uuid::new_v4(), Uuid::new_v4())?;
        jeton.push('x');
        assert!(b.verifier(&jeton).is_err());
        Ok(())
    }

    #[test]
    fn la_cle_se_recharge() -> NvResult<()> {
        let octets = Badge::nouvelle_cle();
        let b1 = Badge::depuis_octets(&octets)?;
        let b2 = Badge::depuis_octets(&octets)?;
        let (jeton, _) = b1.emettre(Uuid::new_v4(), Uuid::new_v4())?;
        assert!(b2.verifier(&jeton).is_ok());
        Ok(())
    }
}
