//! **Le Rust n'appelle aucune fonction de l'ancien gardien SQL.**
//!
//! Le nouveau gardien doit tenir TOUTES les règles lui-même : s'il appelait
//! une fonction de l'ancien (`private.are_connected(…)`), la règle vivrait
//! encore dans la base et disparaîtrait avec elle. Ce test relève, dans le
//! texte SQL écrit dans le code Rust, tout appel à une fonction des schémas
//! `public` et `private` de la base locale — sauf les FONDATIONS, qui
//! restent dans la base (docs/serveur-rust.md) et que le Rust n'appelle de
//! toute façon pas.
use std::path::{Path, PathBuf};

use regex::Regex;
use sqlx::PgPool;

fn fichiers(dir: &Path, sortie: &mut Vec<PathBuf>) {
    if let Ok(entrees) = std::fs::read_dir(dir) {
        for e in entrees.flatten() {
            let p = e.path();
            if p.is_dir() {
                fichiers(&p, sortie);
            } else if p.extension().is_some_and(|x| x == "rs") {
                sortie.push(p);
            }
        }
    }
}

/// Les textes entre guillemets d'un fichier Rust (bruts `r#"…"#` et simples).
fn textes(source: &str) -> Vec<(usize, String)> {
    let brut = Regex::new(r##"(?s)r#"(.*?)"#"##).ok();
    let simple = Regex::new(r#"(?s)"((?:[^"\\]|\\.)*)""#).ok();
    let mut sortie = Vec::new();
    let mut reste = source.to_string();
    if let Some(b) = brut {
        for m in b.captures_iter(source) {
            if let Some(g) = m.get(1) {
                let ligne = source[..g.start()].lines().count();
                sortie.push((ligne, g.as_str().to_string()));
            }
        }
        reste = b.replace_all(source, "\"\"").to_string();
    }
    if let Some(s) = simple {
        for m in s.captures_iter(&reste) {
            if let Some(g) = m.get(1) {
                sortie.push((0, g.as_str().to_string()));
            }
        }
    }
    sortie
}

#[tokio::test]
async fn aucun_appel_a_l_ancien_gardien() {
    let pool = match PgPool::connect("postgres://postgres:neovibe@localhost:54329/postgres").await {
        Ok(p) => p,
        Err(e) => panic!("base locale : {e}"),
    };
    let noms: Vec<String> = match sqlx::query_scalar(
        "select distinct p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname in ('public', 'private') and p.prokind = 'f'",
    )
    .fetch_all(&pool)
    .await
    {
        Ok(n) => n,
        Err(e) => panic!("{e}"),
    };
    let appel = match Regex::new(&format!(r"(?i)\b(?:(?:public|private)\.)?({})\s*\(", noms.join("|"))) {
        Ok(r) => r,
        Err(e) => panic!("{e}"),
    };
    let mut src = Vec::new();
    fichiers(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src"), &mut src);
    let mut fautes = Vec::new();
    for f in src {
        let source = std::fs::read_to_string(&f).unwrap_or_default();
        for (ligne, texte) in textes(&source) {
            for m in appel.captures_iter(&texte) {
                if let Some(nom) = m.get(1) {
                    fautes.push(format!("{}:{} appelle `{}(`", f.display(), ligne, nom.as_str()));
                }
            }
        }
    }
    assert!(fautes.is_empty(), "le Rust appelle l'ancien gardien :\n{}", fautes.join("\n"));
}
