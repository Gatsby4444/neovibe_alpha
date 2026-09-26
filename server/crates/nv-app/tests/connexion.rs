//! La connexion, contre la base locale de travail (outils/base_locale.py).
//!
//! Chaque test travaille dans une transaction ANNULÉE à la fin : la base
//! locale n'en garde rien.
use nv_app::comptes::badge::Badge;
use nv_app::comptes::connexion as cx;
use nv_core::NvError;
use sqlx::{PgConnection, PgPool};

async fn pool() -> PgPool {
    let url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://postgres:neovibe@localhost:54329/postgres".into());
    match PgPool::connect(&url).await {
        Ok(p) => p,
        Err(e) => panic!("base locale injoignable : {e}"),
    }
}

fn empreinte(n: u8) -> String {
    format!("{:02x}", n).repeat(32)
}

fn message(e: NvError) -> String {
    e.to_string()
}

/// L'ancien plafond : la fonction SQL que Supabase appelait avant de créer
/// un compte. `None` = accepté, `Some(message)` = refusé.
async fn ancien_plafond(db: &mut PgConnection, hash: Option<&str>) -> Option<String> {
    let r: serde_json::Value = match sqlx::query_scalar(
        "select public.hook_before_user_created(jsonb_build_object('user',
                jsonb_build_object('user_metadata', jsonb_build_object('device_hash', $1::text))))::json",
    )
    .bind(hash)
    .fetch_one(db)
    .await
    {
        Ok(v) => v,
        Err(e) => panic!("ancien plafond : {e}"),
    };
    r.get("error").and_then(|e| e.get("message")).and_then(|m| m.as_str()).map(String::from)
}

#[tokio::test]
async fn le_plafond_rust_repond_comme_l_ancien() -> Result<(), NvError> {
    let pool = pool().await;
    let mut tx = pool.begin().await?;
    let badge = Badge::ephemere();
    let h = empreinte(0xa1);
    // Une empreinte absente ou mal formée, puis 0, 1, 2 et 3 comptes créés.
    for mauvaise in [None, Some("abc"), Some("A1A1")] {
        let ancien = ancien_plafond(&mut tx, mauvaise).await;
        let nouveau = cx::plafond_du_telephone(&mut tx, mauvaise).await.err().map(message);
        assert_eq!(ancien, nouveau, "empreinte {mauvaise:?}");
    }
    for i in 0..4 {
        let ancien = ancien_plafond(&mut tx, Some(&h)).await;
        let nouveau = cx::plafond_du_telephone(&mut tx, Some(&h)).await.err().map(message);
        assert_eq!(ancien, nouveau, "après {i} compte(s)");
        if nouveau.is_none() {
            cx::inscrire(&mut tx, &badge, &format!("plafond{i}@preuve.fr"), "secret123", Some(&h), None)
                .await?;
        } else {
            assert_eq!(i, 3, "le plafond est de 3 comptes");
        }
    }
    // Un téléphone exempté n'a pas de plafond, des deux côtés.
    sqlx::query("insert into private.signup_device_exempt (device_hash, note) values ($1, 'preuve')")
        .bind(&h)
        .execute(&mut *tx)
        .await?;
    assert_eq!(ancien_plafond(&mut tx, Some(&h)).await, None);
    assert!(cx::plafond_du_telephone(&mut tx, Some(&h)).await.is_ok());
    tx.rollback().await?;
    Ok(())
}

#[tokio::test]
async fn inscription_connexion_renouvellement_deconnexion() -> Result<(), NvError> {
    let pool = pool().await;
    let mut tx = pool.begin().await?;
    let badge = Badge::ephemere();
    let h = empreinte(0xb2);

    let j = cx::inscrire(&mut tx, &badge, " Nouvel@Preuve.FR ", "secret123", Some(&h), Some("test")).await?;
    assert_eq!(j.user.email, "nouvel@preuve.fr");
    assert_eq!(badge.verifier(&j.access_token)?.0, j.user.id);
    let registre: i64 = sqlx::query_scalar("select count(*) from private.device_signups where user_id = $1")
        .bind(j.user.id)
        .fetch_one(&mut *tx)
        .await?;
    assert_eq!(registre, 1, "l'inscription note le téléphone");

    // Mêmes adresse : refus ; mot de passe trop court : refus.
    let e = cx::inscrire(&mut tx, &badge, "nouvel@preuve.fr", "secret123", Some(&h), None).await;
    assert_eq!(e.err().map(message).as_deref(), Some("Un compte existe déjà avec cette adresse."));
    let e = cx::inscrire(&mut tx, &badge, "autre@preuve.fr", "12345", Some(&h), None).await;
    assert_eq!(e.err().map(message).as_deref(), Some("Le mot de passe doit contenir au moins 6 caractères."));

    // Connexion : bon mot de passe, mauvais, adresse inconnue — même refus.
    assert!(cx::connecter(&mut tx, &badge, "NOUVEL@preuve.fr", "secret123", None).await.is_ok());
    let faux = cx::connecter(&mut tx, &badge, "nouvel@preuve.fr", "faux", None).await.err().map(message);
    let inconnu = cx::connecter(&mut tx, &badge, "personne@preuve.fr", "x", None).await.err().map(message);
    assert_eq!(faux, inconnu);
    assert_eq!(faux.as_deref(), Some("Adresse ou mot de passe incorrect."));

    // Renouvellement : le jeton tourne.
    let j2 = cx::renouveler(&mut tx, &badge, &j.refresh_token).await?;
    assert_ne!(j2.refresh_token, j.refresh_token);
    // Le même jeton, réutilisé dans les 10 s (l'app et son service natif) : accepté.
    assert!(cx::renouveler(&mut tx, &badge, &j.refresh_token).await.is_ok());
    // Réutilisé plus tard : c'est un vol, TOUTE la session tombe.
    sqlx::query("update nv.refresh_tokens set used_at = now() - interval '11 seconds' where session_id = (select session_id from nv.refresh_tokens where used_at is not null limit 1)")
        .execute(&mut *tx)
        .await?;
    let vole = cx::renouveler(&mut tx, &badge, &j.refresh_token).await;
    assert!(matches!(vole, Err(NvError::Unauthenticated)));
    let apres = cx::renouveler(&mut tx, &badge, &j2.refresh_token).await;
    assert!(matches!(apres, Err(NvError::Unauthenticated)), "la session révoquée ne renouvelle plus rien");

    // Déconnexion d'une autre session.
    let j3 = cx::connecter(&mut tx, &badge, "nouvel@preuve.fr", "secret123", None).await?;
    let (_, session) = badge.verifier(&j3.access_token)?;
    cx::deconnecter(&mut tx, session).await?;
    assert!(matches!(cx::renouveler(&mut tx, &badge, &j3.refresh_token).await, Err(NvError::Unauthenticated)));
    tx.rollback().await?;
    Ok(())
}

#[tokio::test]
async fn un_compte_venu_de_supabase_se_connecte_et_passe_en_argon2() -> Result<(), NvError> {
    let pool = pool().await;
    let mut tx = pool.begin().await?;
    let badge = Badge::ephemere();
    let bcrypt = match bcrypt::hash("ancien123", 4) {
        Ok(h) => h,
        Err(e) => panic!("{e}"),
    };
    // Le compte Testeur, avec une empreinte bcrypt comme celles de Supabase.
    sqlx::query("update auth.users set encrypted_password = $1 where email is not null and id = '135ed9b3-03a0-4f28-a2f3-784223a2dcde'")
        .bind(&bcrypt)
        .execute(&mut *tx)
        .await?;
    let email: String = sqlx::query_scalar("select email from auth.users where id = '135ed9b3-03a0-4f28-a2f3-784223a2dcde'")
        .fetch_one(&mut *tx)
        .await?;
    cx::connecter(&mut tx, &badge, &email, "ancien123", None).await?;
    let apres: String = sqlx::query_scalar("select encrypted_password from auth.users where id = '135ed9b3-03a0-4f28-a2f3-784223a2dcde'")
        .fetch_one(&mut *tx)
        .await?;
    assert!(apres.starts_with("$argon2id$"), "l'empreinte a été réécrite");
    // Et le même mot de passe marche toujours.
    cx::connecter(&mut tx, &badge, &email, "ancien123", None).await?;
    tx.rollback().await?;
    Ok(())
}
