//! **La preuve par comparaison** (docs/serveur-rust.md §4).
//!
//! Chaque situation d'un fichier `server/preuves/*.toml` est jouée deux fois,
//! dans UNE transaction de la base locale, à partir du même état :
//!
//! 1. par l'**ancien gardien** — la fonction SQL d'aujourd'hui, appelée sous
//!    l'identité du compte (`set local role authenticated` +
//!    `request.jwt.claims`), comme le faisait le guichet de Supabase ;
//! 2. par le **nouveau gardien** — l'opération Rust du registre.
//!
//! Entre les deux, retour au point de sauvegarde : aucune trace de l'un ne
//! reste pour l'autre. Les deux partagent la même heure (`now()` est celle
//! de la transaction). On compare la réponse (acceptée ou refusée, avec le
//! même message ; les mêmes données) et le **journal des changements**
//! (`nv_proof.changes`, `server/outils/preuve.sql`) : les mêmes lignes
//! écrites, modifiées ou supprimées.
//!
//! Usage : `bash outils/cargo.sh run -p nv-proof -- [filtre]`
//! Sortie non nulle si une seule situation diffère.
mod cas;
mod compare;
mod jouer;

use std::collections::HashMap;
use std::process::ExitCode;

use sqlx::postgres::PgPoolOptions;

#[tokio::main]
async fn main() -> ExitCode {
    let filtre = std::env::args().nth(1).unwrap_or_default();
    let url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://postgres:neovibe@localhost:54329/postgres".into());
    let pool = match PgPoolOptions::new().max_connections(2).connect(&url).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Base locale injoignable ({url}) : {e}");
            return ExitCode::FAILURE;
        }
    };
    let cas = match cas::charger(&filtre) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let registre: HashMap<&'static str, nv_core::ops::OpFn> =
        nv_app::registry().into_iter().map(|o| (o.name, o.run)).collect();
    let series = match jouer::colonnes_de_serie(&pool).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };

    let (mut ok, mut ko) = (0usize, 0usize);
    for c in &cas {
        match jouer::jouer(&pool, &registre, &series, c).await {
            Ok(verdict) if verdict.is_empty() => {
                ok += 1;
                println!("ok    {} · {}", c.fichier, c.nom);
                if let Some(raison) = &c.ecart {
                    println!("      (écart voulu sur {:?} : {raison})", c.ecart_champs);
                }
            }
            Ok(verdict) => {
                ko += 1;
                println!("DIFF  {} · {}", c.fichier, c.nom);
                for l in verdict {
                    println!("      {l}");
                }
            }
            Err(e) => {
                ko += 1;
                println!("PANNE {} · {} : {e}", c.fichier, c.nom);
            }
        }
    }
    println!("\n{} situation(s) : {ok} identique(s), {ko} différente(s)", ok + ko);
    if ko == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
