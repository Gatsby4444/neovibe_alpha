//! Les situations à jouer : `server/preuves/*.toml`.
//!
//! ```toml
//! [[cas]]
//! nom = "un nom déjà pris"
//! qui = "charles"                 # un alias de preuves/qui.toml, un uuid, ou "anon"
//! rpc = "username_available"      # l'ancienne fonction SQL (public.…)
//! op = "username_available"       # l'opération Rust (par défaut : rpc)
//! args = { p_username = "charles" }
//! # ancien = "insert into …"      # au lieu de rpc : du SQL joué sous l'identité
//! # ancien_resultat = "select …"  # la réponse de l'ancien (une valeur json)
//! # avant = "update …"            # mise en place, jouée pour les deux côtés
//! # sans_ordre = true             # les listes se comparent sans l'ordre
//! # equivalence = "sans_effet"    # l'ancien acceptait sans rien changer, le nouveau refuse
//! # attendu = "refuse"            # garde-fou : la situation doit bien refuser
//! # ignorer = ["public.x"]        # tables à ne pas comparer
//! ```
//!
//! `{{alias}}` est remplacé par l'identifiant du compte, partout.
use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
struct Fichier {
    #[serde(default)]
    cas: Vec<CasBrut>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CasBrut {
    nom: String,
    qui: String,
    rpc: Option<String>,
    op: Option<String>,
    #[serde(default)]
    args: Option<toml::Value>,
    ancien: Option<String>,
    ancien_resultat: Option<String>,
    avant: Option<String>,
    #[serde(default)]
    sans_ordre: bool,
    equivalence: Option<String>,
    attendu: Option<String>,
    #[serde(default)]
    ignorer: Vec<String>,
    /// Un écart VOULU entre l'ancien et le nouveau : sa raison…
    ecart: Option<String>,
    /// … et les champs de la réponse qu'il concerne (masqués des deux côtés).
    #[serde(default)]
    ecart_champs: Vec<String>,
    /// Garde-fou : l'ancien gardien DOIT écrire dans ces tables (sinon la
    /// situation ne teste rien).
    #[serde(default)]
    doit_changer: Vec<String>,
}

/// Une situation prête à jouer.
#[derive(Debug)]
pub struct Cas {
    pub fichier: String,
    pub nom: String,
    /// `None` = personne n'est connecté.
    pub qui: Option<uuid::Uuid>,
    pub rpc: Option<String>,
    pub op: String,
    pub args: Value,
    pub ancien: Option<String>,
    pub ancien_resultat: Option<String>,
    pub avant: Option<String>,
    pub sans_ordre: bool,
    pub sans_effet: bool,
    /// Écart voulu : le nouveau refuse ce que l'ancien acceptait (avec une
    /// raison obligatoire dans `ecart`).
    pub plus_strict: bool,
    pub attendu: Option<String>,
    pub ignorer: Vec<String>,
    pub ecart: Option<String>,
    pub ecart_champs: Vec<String>,
    pub doit_changer: Vec<String>,
}

fn creneau_textuel(s: &str, creneau: i64) -> String {
    let mut sortie = s.to_string();
    for d in (-400..=400).rev() {
        let motif = if d == 0 { "{{creneau}}".to_string() } else if d > 0 { format!("{{{{creneau+{d}}}}}") } else { format!("{{{{creneau{d}}}}}") };
        if sortie.contains(&motif) {
            sortie = sortie.replace(&motif, &(creneau + d).to_string());
        }
    }
    sortie
}

fn creneau_json(v: &Value, creneau: i64) -> Value {
    match v {
        Value::String(s) => {
            let r = creneau_textuel(s, creneau);
            // Une valeur qui n'était QUE le créneau devient un nombre.
            if s.starts_with("{{creneau") && s.ends_with("}}") {
                r.parse::<i64>().map(Value::from).unwrap_or(Value::String(r))
            } else {
                Value::String(r)
            }
        }
        Value::Array(a) => Value::Array(a.iter().map(|x| creneau_json(x, creneau)).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), creneau_json(x, creneau))).collect()),
        autre => autre.clone(),
    }
}

/// La situation, avec le créneau de ping de sa transaction à la place de
/// `{{creneau}}`, `{{creneau-1}}`, `{{creneau+2}}`…
pub fn avec_creneau(c: &Cas, creneau: i64) -> Cas {
    Cas {
        fichier: c.fichier.clone(),
        nom: c.nom.clone(),
        qui: c.qui,
        rpc: c.rpc.clone(),
        op: c.op.clone(),
        args: creneau_json(&c.args, creneau),
        ancien: c.ancien.as_deref().map(|s| creneau_textuel(s, creneau)),
        ancien_resultat: c.ancien_resultat.as_deref().map(|s| creneau_textuel(s, creneau)),
        avant: c.avant.as_deref().map(|s| creneau_textuel(s, creneau)),
        sans_ordre: c.sans_ordre,
        sans_effet: c.sans_effet,
        plus_strict: c.plus_strict,
        attendu: c.attendu.clone(),
        ignorer: c.ignorer.clone(),
        ecart: c.ecart.clone(),
        ecart_champs: c.ecart_champs.clone(),
        doit_changer: c.doit_changer.clone(),
    }
}

fn dossier() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../preuves")
}

fn remplacer(s: &str, qui: &BTreeMap<String, String>) -> String {
    let mut s = s.to_string();
    for (alias, id) in qui {
        s = s.replace(&format!("{{{{{alias}}}}}"), id);
    }
    s
}

fn remplacer_json(v: Value, qui: &BTreeMap<String, String>) -> Value {
    match v {
        Value::String(s) => Value::String(remplacer(&s, qui)),
        Value::Array(a) => Value::Array(a.into_iter().map(|x| remplacer_json(x, qui)).collect()),
        Value::Object(o) => {
            Value::Object(o.into_iter().map(|(k, x)| (k, remplacer_json(x, qui))).collect())
        }
        autre => autre,
    }
}

/// Charge toutes les situations dont le fichier ou le nom contient `filtre`.
pub fn charger(filtre: &str) -> Result<Vec<Cas>, String> {
    let d = dossier();
    let qui: BTreeMap<String, String> = {
        let t = std::fs::read_to_string(d.join("qui.toml")).map_err(|e| format!("qui.toml : {e}"))?;
        let v: BTreeMap<String, BTreeMap<String, String>> =
            toml::from_str(&t).map_err(|e| format!("qui.toml : {e}"))?;
        v.get("qui").cloned().unwrap_or_default()
    };
    let mut fichiers: Vec<_> = std::fs::read_dir(&d)
        .map_err(|e| format!("{} : {e}", d.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "toml") && !p.ends_with("qui.toml"))
        .collect();
    fichiers.sort();
    let mut tout = Vec::new();
    for p in fichiers {
        let nom_fichier = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let texte = std::fs::read_to_string(&p).map_err(|e| format!("{} : {e}", p.display()))?;
        let f: Fichier = toml::from_str(&texte).map_err(|e| format!("{} : {e}", p.display()))?;
        for c in f.cas {
            if !filtre.is_empty() && !nom_fichier.contains(filtre) && !c.nom.contains(filtre) {
                continue;
            }
            let qui_id = match c.qui.as_str() {
                "anon" => None,
                alias => {
                    let brut = qui.get(alias).cloned().unwrap_or_else(|| alias.to_string());
                    Some(uuid::Uuid::parse_str(&brut).map_err(|_| {
                        format!("{} · {} : qui = « {} » inconnu", nom_fichier, c.nom, c.qui)
                    })?)
                }
            };
            let args = match c.args {
                Some(t) => serde_json::to_value(t).map_err(|e| format!("{} : {e}", c.nom))?,
                None => Value::Object(Default::default()),
            };
            let op = c.op.clone().or_else(|| c.rpc.clone()).ok_or_else(|| {
                format!("{} · {} : ni `op` ni `rpc`", nom_fichier, c.nom)
            })?;
            tout.push(Cas {
                fichier: nom_fichier.clone(),
                nom: c.nom,
                qui: qui_id,
                rpc: c.rpc,
                op,
                args: remplacer_json(args, &qui),
                ancien: c.ancien.map(|s| remplacer(&s, &qui)),
                ancien_resultat: c.ancien_resultat.map(|s| remplacer(&s, &qui)),
                avant: c.avant.map(|s| remplacer(&s, &qui)),
                sans_ordre: c.sans_ordre,
                sans_effet: c.equivalence.as_deref() == Some("sans_effet"),
                plus_strict: c.equivalence.as_deref() == Some("plus_strict"),
                attendu: c.attendu,
                ignorer: c.ignorer,
                ecart: c.ecart,
                ecart_champs: c.ecart_champs,
                doit_changer: c.doit_changer,
            });
        }
    }
    Ok(tout)
}
