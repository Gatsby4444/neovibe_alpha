//! L'entrepôt réel : n'importe quel stockage **compatible S3** (AWS S3,
//! Cloudflare R2, SeaweedFS en local…).
//!
//! Les liens donnés au téléphone sont signés avec l'adresse PUBLIQUE de
//! l'entrepôt (celle que le téléphone joint) ; les gestes du serveur
//! (ouvrir, terminer, supprimer) passent par son adresse INTERNE. Les deux
//! peuvent être la même.
//!
//! Chaque coffre logique (`avatars`, `cards`…) est un « bucket » S3 dont le
//! nom porte un préfixe (`NV_S3_PREFIXE`) : sur AWS, un nom de bucket est
//! unique au monde.
use std::time::Duration;

use futures::future::BoxFuture;
use futures::FutureExt;
use rusty_s3::actions::{CreateMultipartUpload, ListParts};
use rusty_s3::{Bucket, Credentials, S3Action, UrlStyle};
use url::Url;

use nv_core::fichiers::{Entrepot, Morceau};
use nv_core::{NvError, NvResult};

/// Les réglages de l'entrepôt.
#[derive(Debug, Clone)]
pub struct Reglages {
    /// L'adresse que le SERVEUR joint (ex. `http://127.0.0.1:8333`).
    pub interne: Url,
    /// L'adresse que le TÉLÉPHONE joint (signée dans les liens).
    pub publique: Url,
    pub region: String,
    pub cle: String,
    pub secret: String,
    /// Préfixe des noms de buckets (ex. `neovibe-`).
    pub prefixe: String,
}

pub struct EntrepotS3 {
    r: Reglages,
    creds: Credentials,
    http: reqwest::Client,
}

fn panne(quoi: &str, e: impl std::fmt::Display) -> NvError {
    NvError::Internal(format!("entrepôt ({quoi}) : {e}"))
}

impl EntrepotS3 {
    pub fn new(r: Reglages) -> NvResult<Self> {
        let creds = Credentials::new(r.cle.clone(), r.secret.clone());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .map_err(|e| panne("client", e))?;
        Ok(EntrepotS3 { r, creds, http })
    }

    fn bucket(&self, adresse: &Url, coffre: &str) -> NvResult<Bucket> {
        Bucket::new(adresse.clone(), UrlStyle::Path, format!("{}{}", self.r.prefixe, coffre), self.r.region.clone())
            .map_err(|e| panne("bucket", e))
    }

    fn interne(&self, coffre: &str) -> NvResult<Bucket> {
        self.bucket(&self.r.interne, coffre)
    }

    fn publique(&self, coffre: &str) -> NvResult<Bucket> {
        self.bucket(&self.r.publique, coffre)
    }

    /// Crée les coffres qui n'existent pas encore (développement ; en
    /// production, ils sont créés une fois pour toutes).
    pub async fn preparer(&self, coffres: &[&str]) -> NvResult<()> {
        for c in coffres {
            let b = self.interne(c)?;
            let tete = b.head_bucket(Some(&self.creds)).sign(Duration::from_secs(60));
            let r = self.http.head(tete).send().await.map_err(|e| panne("head bucket", e))?;
            if r.status().is_success() {
                continue;
            }
            let url = b.create_bucket(&self.creds).sign(Duration::from_secs(60));
            let r = self.http.put(url).send().await.map_err(|e| panne("create bucket", e))?;
            if !r.status().is_success() {
                return Err(panne("create bucket", format!("{c} : {}", r.status())));
            }
            tracing::info!("coffre créé : {}{c}", self.r.prefixe);
        }
        Ok(())
    }
}

const SIGNATURE: Duration = Duration::from_secs(300);

impl Entrepot for EntrepotS3 {
    fn lien_lecture(&self, bucket: &str, chemin: &str, duree_s: u64) -> NvResult<String> {
        let b = self.publique(bucket)?;
        Ok(b.get_object(Some(&self.creds), chemin).sign(Duration::from_secs(duree_s)).to_string())
    }

    fn lien_depot(&self, bucket: &str, chemin: &str, type_: &str, taille: u64, duree_s: u64) -> NvResult<String> {
        let b = self.publique(bucket)?;
        let mut a = b.put_object(Some(&self.creds), chemin);
        a.headers_mut().insert("content-type", type_.to_string());
        a.headers_mut().insert("content-length", taille.to_string());
        Ok(a.sign(Duration::from_secs(duree_s)).to_string())
    }

    fn lien_morceau(&self, bucket: &str, chemin: &str, envoi: &str, numero: u16, duree_s: u64) -> NvResult<String> {
        let b = self.publique(bucket)?;
        Ok(b.upload_part(Some(&self.creds), chemin, numero, envoi).sign(Duration::from_secs(duree_s)).to_string())
    }

    fn ouvrir_envoi<'a>(&'a self, bucket: &'a str, chemin: &'a str, type_: &'a str) -> BoxFuture<'a, NvResult<String>> {
        async move {
            let b = self.interne(bucket)?;
            let mut a = b.create_multipart_upload(Some(&self.creds), chemin);
            a.headers_mut().insert("content-type", type_.to_string());
            let url = a.sign(SIGNATURE);
            let r = self
                .http
                .post(url)
                .header("content-type", type_)
                .send()
                .await
                .map_err(|e| panne("ouvrir", e))?;
            let statut = r.status();
            let corps = r.text().await.map_err(|e| panne("ouvrir", e))?;
            if !statut.is_success() {
                return Err(panne("ouvrir", format!("{statut} {corps}")));
            }
            let rep = CreateMultipartUpload::parse_response(&corps).map_err(|e| panne("ouvrir", e))?;
            Ok(rep.upload_id().to_string())
        }
        .boxed()
    }

    fn morceaux<'a>(&'a self, bucket: &'a str, chemin: &'a str, envoi: &'a str) -> BoxFuture<'a, NvResult<Option<Vec<Morceau>>>> {
        async move {
            let b = self.interne(bucket)?;
            let mut tous = Vec::new();
            let mut repere: Option<u16> = None;
            loop {
                let mut a = b.list_parts(Some(&self.creds), chemin, envoi);
                if let Some(m) = repere {
                    a.set_part_number_marker(m);
                }
                let r = self.http.get(a.sign(SIGNATURE)).send().await.map_err(|e| panne("morceaux", e))?;
                if r.status() == reqwest::StatusCode::NOT_FOUND {
                    return Ok(None);
                }
                let statut = r.status();
                let corps = r.text().await.map_err(|e| panne("morceaux", e))?;
                if !statut.is_success() {
                    if corps.contains("NoSuchUpload") {
                        return Ok(None);
                    }
                    return Err(panne("morceaux", format!("{statut} {corps}")));
                }
                let rep = ListParts::parse_response(&corps).map_err(|e| panne("morceaux", e))?;
                for p in &rep.parts {
                    tous.push(Morceau { numero: p.number, etag: p.etag.clone(), taille: p.size });
                }
                match rep.next_part_number_marker {
                    Some(m) if rep.parts.len() as u16 >= rep.max_parts && repere != Some(m) => repere = Some(m),
                    _ => break,
                }
            }
            tous.sort_by_key(|m| m.numero);
            Ok(Some(tous))
        }
        .boxed()
    }

    fn terminer_envoi<'a>(&'a self, bucket: &'a str, chemin: &'a str, envoi: &'a str, morceaux: Vec<Morceau>) -> BoxFuture<'a, NvResult<()>> {
        async move {
            let b = self.interne(bucket)?;
            let a = b.complete_multipart_upload(Some(&self.creds), chemin, envoi, morceaux.iter().map(|m| m.etag.as_str()));
            let url = a.sign(SIGNATURE);
            let corps = a.body();
            let r = self.http.post(url).body(corps).send().await.map_err(|e| panne("terminer", e))?;
            let statut = r.status();
            let texte = r.text().await.map_err(|e| panne("terminer", e))?;
            // S3 peut répondre 200 avec une erreur dans le corps.
            if !statut.is_success() || texte.contains("<Error>") {
                return Err(panne("terminer", format!("{statut} {texte}")));
            }
            Ok(())
        }
        .boxed()
    }

    fn abandonner_envoi<'a>(&'a self, bucket: &'a str, chemin: &'a str, envoi: &'a str) -> BoxFuture<'a, NvResult<()>> {
        async move {
            let b = self.interne(bucket)?;
            let url = b.abort_multipart_upload(Some(&self.creds), chemin, envoi).sign(SIGNATURE);
            let r = self.http.delete(url).send().await.map_err(|e| panne("abandonner", e))?;
            if !r.status().is_success() && r.status() != reqwest::StatusCode::NOT_FOUND {
                return Err(panne("abandonner", r.status()));
            }
            Ok(())
        }
        .boxed()
    }

    fn taille<'a>(&'a self, bucket: &'a str, chemin: &'a str) -> BoxFuture<'a, NvResult<Option<u64>>> {
        async move {
            let b = self.interne(bucket)?;
            let url = b.head_object(Some(&self.creds), chemin).sign(SIGNATURE);
            let r = self.http.head(url).send().await.map_err(|e| panne("taille", e))?;
            if r.status() == reqwest::StatusCode::NOT_FOUND {
                return Ok(None);
            }
            if !r.status().is_success() {
                return Err(panne("taille", r.status()));
            }
            Ok(r
                .headers()
                .get(reqwest::header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse().ok())
                .or(Some(0)))
        }
        .boxed()
    }

    fn supprimer<'a>(&'a self, bucket: &'a str, chemins: Vec<String>) -> BoxFuture<'a, NvResult<()>> {
        async move {
            let b = self.interne(bucket)?;
            for c in &chemins {
                let url = b.delete_object(Some(&self.creds), c).sign(SIGNATURE);
                let r = self.http.delete(url).send().await.map_err(|e| panne("supprimer", e))?;
                if !r.status().is_success() && r.status() != reqwest::StatusCode::NOT_FOUND {
                    return Err(panne("supprimer", format!("{c} : {}", r.status())));
                }
            }
            Ok(())
        }
        .boxed()
    }
}
