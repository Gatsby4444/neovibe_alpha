//! Comparer ce que les deux gardiens ont produit.
//!
//! Ce qui diffère FORCÉMENT d'un côté à l'autre est neutralisé avant la
//! comparaison, et seulement cela :
//! - les identifiants tirés au hasard des lignes créées (`id` d'une ligne
//!   insérée) : remplacés par `<id1>`, `<id2>`… dans un ordre canonique ;
//! - les colonnes remplies par un compteur (`nextval`, identité) ;
//! - l'écriture des nombres (`5` et `5.0` sont le même nombre).
//!
//! L'heure n'a pas à l'être : les deux côtés partagent la transaction, donc
//! le même `now()`.
use std::collections::{HashMap, HashSet};

use serde_json::{Map, Number, Value};

use crate::cas::Cas;
use crate::jouer::{Change, Cote};

/// L'issue d'un côté.
#[derive(Debug, Clone)]
pub enum Issue {
    /// Accepté, avec la réponse.
    Ok(Value),
    /// Refusé. `P0001` = un refus d'une règle (`raise exception`), dont le
    /// message est montré à l'utilisateur : il doit être identique.
    Refus { sqlstate: String, message: String },
    /// Le nouveau gardien est tombé en panne (erreur de base inattendue).
    PanneNouveau(String),
}

fn est_uuid(s: &str) -> bool {
    s.len() == 36 && uuid::Uuid::parse_str(s).is_ok()
}

/// Nombres : une seule écriture pour une même valeur.
fn nombres(v: &Value) -> Value {
    match v {
        Value::Number(n) => {
            let f = n.as_f64().unwrap_or(0.0);
            if f.fract() == 0.0 && f.abs() < 9.0e15 {
                Value::Number(Number::from(f as i64))
            } else {
                Number::from_f64(f).map(Value::Number).unwrap_or(Value::Null)
            }
        }
        Value::Array(a) => Value::Array(a.iter().map(nombres).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), nombres(x))).collect()),
        autre => autre.clone(),
    }
}

fn remplacer(v: &Value, table: &HashMap<String, String>) -> Value {
    match v {
        Value::String(s) => table.get(s).map(|p| Value::String(p.clone())).unwrap_or_else(|| v.clone()),
        Value::Array(a) => Value::Array(a.iter().map(|x| remplacer(x, table)).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), remplacer(x, table))).collect()),
        autre => autre.clone(),
    }
}

fn masquer(v: &Value, cols: &[String]) -> Value {
    match v {
        Value::Object(o) => {
            let mut m = Map::new();
            for (k, x) in o {
                m.insert(k.clone(), if cols.contains(k) { Value::String("<série>".into()) } else { x.clone() });
            }
            Value::Object(m)
        }
        autre => autre.clone(),
    }
}

/// Neutralise un côté ; renvoie (réponse, changements canoniques triés).
fn neutraliser(
    reponse: &Value,
    changes: &[Change],
    series: &HashSet<(String, String)>,
    ignorer: &[String],
) -> (Value, Vec<String>) {
    // 1. Les identifiants créés : l'`id` des lignes insérées.
    let mut crees: Vec<(String, String, String)> = Vec::new(); // (clé de tri, id, table)
    for c in changes {
        if c.op == "INSERT" {
            if let Some(Value::String(id)) = c.new.get("id") {
                if est_uuid(id) {
                    let mut sans_id = c.new.clone();
                    if let Some(o) = sans_id.as_object_mut() {
                        o.insert("id".into(), Value::String("<id>".into()));
                    }
                    crees.push((format!("{}|{}", c.tbl, sans_id), id.clone(), c.tbl.clone()));
                }
            }
        }
    }
    crees.sort();
    let table: HashMap<String, String> =
        crees.iter().enumerate().map(|(i, (_, id, _))| (id.clone(), format!("<id{}>", i + 1))).collect();

    // 2. Les changements, colonnes de série masquées, sous forme canonique.
    let mut lignes: Vec<String> = changes
        .iter()
        .filter(|c| !ignorer.contains(&c.tbl))
        .map(|c| {
            let cols: Vec<String> = series.iter().filter(|(t, _)| *t == c.tbl).map(|(_, col)| col.clone()).collect();
            let old = nombres(&remplacer(&masquer(&c.old, &cols), &table));
            let new = nombres(&remplacer(&masquer(&c.new, &cols), &table));
            format!("{} {} {} -> {}", c.op, c.tbl, old, new)
        })
        .collect();
    lignes.sort();
    (nombres(&remplacer(reponse, &table)), lignes)
}

/// Les champs d'un écart voulu, masqués des deux côtés.
fn masquer_ecart(v: &Value, champs: &[String]) -> Value {
    if champs.is_empty() {
        return v.clone();
    }
    match v {
        Value::Array(a) => Value::Array(a.iter().map(|x| masquer_ecart(x, champs)).collect()),
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, x)| {
                    let x = if champs.contains(k) { Value::String("<écart voulu>".into()) } else { masquer_ecart(x, champs) };
                    (k.clone(), x)
                })
                .collect(),
        ),
        autre => autre.clone(),
    }
}

fn canon_liste(v: &Value) -> Value {
    match v {
        Value::Array(a) => {
            let mut s: Vec<String> = a.iter().map(|x| x.to_string()).collect();
            s.sort();
            Value::Array(s.into_iter().map(Value::String).collect())
        }
        autre => autre.clone(),
    }
}

fn court(v: &Value) -> String {
    let s = v.to_string();
    if s.chars().count() > 600 { format!("{}…", s.chars().take(600).collect::<String>()) } else { s }
}

/// Le verdict : vide si les deux côtés sont identiques.
pub fn verdict(c: &Cas, ancien: &Cote, nouveau: &Cote, series: &HashSet<(String, String)>) -> Vec<String> {
    let mut diff = Vec::new();
    // Garde-fou : la situation produit-elle bien ce qu'elle prétend tester ?
    match (c.attendu.as_deref(), &ancien.issue) {
        (Some("refuse"), Issue::Ok(_)) => diff.push("CAS MAL POSÉ : l'ancien gardien accepte, la situation attendait un refus".into()),
        (Some("accepte"), Issue::Refus { message, .. }) => {
            diff.push(format!("CAS MAL POSÉ : l'ancien gardien refuse (« {message} »), la situation attendait un accord"))
        }
        _ => {}
    }
    for table in &c.doit_changer {
        if !ancien.changes.iter().any(|x| &x.tbl == table) {
            diff.push(format!("CAS MAL POSÉ : l'ancien gardien n'a rien écrit dans {table}"));
        }
    }
    match (&ancien.issue, &nouveau.issue) {
        (_, Issue::PanneNouveau(e)) => diff.push(format!("le nouveau gardien tombe en panne : {e}")),
        (Issue::Ok(a), Issue::Ok(n)) => {
            let (ra, ca) = neutraliser(a, &ancien.changes, series, &c.ignorer);
            let (rn, cn) = neutraliser(n, &nouveau.changes, series, &c.ignorer);
            let (ra, rn) = (masquer_ecart(&ra, &c.ecart_champs), masquer_ecart(&rn, &c.ecart_champs));
            let (ra, rn) = if c.sans_ordre { (canon_liste(&ra), canon_liste(&rn)) } else { (ra, rn) };
            if ra != rn {
                diff.push(format!("réponses différentes\n        ancien  : {}\n        nouveau : {}", court(&ra), court(&rn)));
            }
            if ca != cn {
                let sa: HashSet<&String> = ca.iter().collect();
                let sn: HashSet<&String> = cn.iter().collect();
                for x in ca.iter().filter(|x| !sn.contains(x)) {
                    diff.push(format!("changement de l'ancien seulement : {}", x.chars().take(400).collect::<String>()));
                }
                for x in cn.iter().filter(|x| !sa.contains(x)) {
                    diff.push(format!("changement du nouveau seulement : {}", x.chars().take(400).collect::<String>()));
                }
                if diff.is_empty() {
                    diff.push(format!("mêmes changements, pas le même nombre ({} / {})", ca.len(), cn.len()));
                }
            }
        }
        (Issue::Refus { sqlstate, message }, Issue::Refus { message: m2, .. }) => {
            if sqlstate == "P0001" && message != m2 {
                diff.push(format!("refus au message différent\n        ancien  : {message}\n        nouveau : {m2}"));
            }
        }
        (Issue::Ok(_), Issue::Refus { message, .. }) => {
            if !(c.sans_effet && ancien.changes.is_empty()) {
                diff.push(format!("l'ancien accepte, le nouveau refuse (« {message} »)"));
            }
        }
        (Issue::Refus { message, .. }, Issue::Ok(v)) => {
            diff.push(format!("⚠️ PLUS PERMISSIF : l'ancien refuse (« {message} »), le nouveau accepte ({})", court(v)))
        }
        (Issue::PanneNouveau(_), _) => {}
    }
    diff
}
