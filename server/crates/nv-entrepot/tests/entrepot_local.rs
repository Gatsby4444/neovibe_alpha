//! L'entrepôt réel, contre l'entrepôt LOCAL (SeaweedFS,
//! `outils/entrepot_local.py`) : dépôt signé, lecture signée, envoi en
//! morceaux avec reprise, suppression — et les refus de l'entrepôt quand un
//! dépôt ne respecte pas ce qui a été signé.
use nv_core::fichiers::Entrepot;
use nv_core::NvError;
use nv_entrepot::{EntrepotS3, Reglages};

fn entrepot() -> EntrepotS3 {
    let var = |n: &str| match std::env::var(n) {
        Ok(v) => v,
        Err(_) => panic!("{n} manquante : lancer par outils/cargo.sh après outils/entrepot_local.py"),
    };
    let interne: url::Url = match var("NV_S3_INTERNE").parse() {
        Ok(u) => u,
        Err(e) => panic!("{e}"),
    };
    match EntrepotS3::new(Reglages {
        publique: interne.clone(),
        interne,
        region: var("NV_S3_REGION"),
        cle: var("NV_S3_CLE"),
        secret: var("NV_S3_SECRET"),
        prefixe: "neovibe-test-".into(),
    }) {
        Ok(e) => e,
        Err(e) => panic!("{e}"),
    }
}

#[tokio::test]
async fn deposer_lire_morceaux_supprimer() -> Result<(), NvError> {
    let e = entrepot();
    e.preparer(&["essai"]).await?;
    let http = reqwest::Client::new();
    let panne = |x: reqwest::Error| NvError::Internal(x.to_string());

    // 1. Un dépôt entier, au lien signé.
    let octets = b"des octets scelles".to_vec();
    let lien = e.lien_depot("essai", "moi/un.bin", "application/octet-stream", octets.len() as u64, 300)?;
    let r = http
        .put(&lien)
        .header("content-type", "application/octet-stream")
        .body(octets.clone())
        .send()
        .await
        .map_err(panne)?;
    assert!(r.status().is_success(), "dépôt : {}", r.status());
    assert_eq!(e.taille("essai", "moi/un.bin").await?, Some(octets.len() as u64));

    // Un dépôt d'une AUTRE taille que celle signée : l'entrepôt refuse.
    let lien = e.lien_depot("essai", "moi/deux.bin", "application/octet-stream", 3, 300)?;
    let r = http
        .put(&lien)
        .header("content-type", "application/octet-stream")
        .body(vec![0u8; 10])
        .send()
        .await
        .map_err(panne)?;
    assert!(!r.status().is_success(), "un dépôt plus lourd que signé est refusé");

    // 2. La lecture signée rend les mêmes octets.
    let lu = http
        .get(e.lien_lecture("essai", "moi/un.bin", 300)?)
        .send()
        .await
        .map_err(panne)?
        .bytes()
        .await
        .map_err(panne)?;
    assert_eq!(lu.to_vec(), octets);

    // 3. Un envoi en morceaux (6 Mo + un reste), repris après « coupure ».
    let envoi = e.ouvrir_envoi("essai", "moi/video.bin", "application/octet-stream").await?;
    let m1 = vec![7u8; 6 * 1024 * 1024];
    let m2 = vec![9u8; 1234];
    let r = http.put(e.lien_morceau("essai", "moi/video.bin", &envoi, 1, 300)?).body(m1.clone()).send().await.map_err(panne)?;
    assert!(r.status().is_success(), "morceau 1 : {}", r.status());
    // La « reprise » : ce que l'entrepôt a déjà.
    let recus = e.morceaux("essai", "moi/video.bin", &envoi).await?.unwrap_or_default();
    assert_eq!(recus.len(), 1);
    assert_eq!(recus[0].taille, m1.len() as u64);
    let r = http.put(e.lien_morceau("essai", "moi/video.bin", &envoi, 2, 300)?).body(m2.clone()).send().await.map_err(panne)?;
    assert!(r.status().is_success(), "morceau 2 : {}", r.status());
    let recus = e.morceaux("essai", "moi/video.bin", &envoi).await?.unwrap_or_default();
    assert_eq!(recus.len(), 2);
    e.terminer_envoi("essai", "moi/video.bin", &envoi, recus).await?;
    assert_eq!(e.taille("essai", "moi/video.bin").await?, Some((m1.len() + m2.len()) as u64));

    // 4. Un envoi abandonné n'existe plus.
    let envoi2 = e.ouvrir_envoi("essai", "moi/abandon.bin", "application/octet-stream").await?;
    e.abandonner_envoi("essai", "moi/abandon.bin", &envoi2).await?;
    assert!(e.morceaux("essai", "moi/abandon.bin", &envoi2).await?.is_none());

    // 5. La suppression (un fichier absent n'est pas une erreur).
    e.supprimer("essai", vec!["moi/un.bin".into(), "moi/video.bin".into(), "moi/absent.bin".into()]).await?;
    assert_eq!(e.taille("essai", "moi/un.bin").await?, None);
    assert_eq!(e.taille("essai", "moi/video.bin").await?, None);
    Ok(())
}
