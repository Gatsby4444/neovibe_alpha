//! La lecture des arguments d'une opération.
//!
//! Les guichets reçoivent le même JSON que les fonctions SQL d'aujourd'hui
//! (mêmes noms d'arguments, `p_…`) : c'est ce qui permet à la preuve de
//! jouer la même situation des deux côtés, et à l'app de garder ses appels.
//! Un argument inconnu est refusé, comme le faisait le guichet de Supabase
//! (« fonction introuvable ») : chaque structure d'arguments porte
//! `#[serde(deny_unknown_fields)]`.
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::error::{NvError, NvResult};

/// Lit les arguments d'une opération.
pub fn parse<T: DeserializeOwned>(args: Value) -> NvResult<T> {
    let args = if args.is_null() { Value::Object(Default::default()) } else { args };
    serde_json::from_value(args).map_err(|e| NvError::BadArgs(e.to_string()))
}

/// Aucune entrée attendue : refuse toute clé.
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NoArgs {}
