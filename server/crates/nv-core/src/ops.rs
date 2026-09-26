//! Le registre des guichets : un nom → une fonction.
//!
//! Les noms sont ceux des fonctions SQL d'aujourd'hui (et, pour ce que l'app
//! faisait directement sur les tables, des noms nouveaux). Le guichet HTTP
//! `POST /v1/rpc/{nom}` et la preuve passent par ce même registre : il n'y a
//! qu'un chemin vers chaque opération.
use std::future::Future;
use std::pin::Pin;

use serde_json::Value;

use crate::ctx::Ctx;
use crate::error::NvResult;

pub type OpFuture<'a> = Pin<Box<dyn Future<Output = NvResult<Value>> + Send + 'a>>;
pub type OpFn = for<'a> fn(&'a mut Ctx, Value) -> OpFuture<'a>;

/// Une opération du registre.
#[derive(Clone, Copy)]
pub struct Op {
    pub name: &'static str,
    pub run: OpFn,
}

/// Déclare des opérations : `ops![nom => chemin::vers::fonction, …]`.
///
/// Chaque fonction a la forme `async fn(&mut Ctx, Value) -> NvResult<Value>`.
#[macro_export]
macro_rules! ops {
    ($($name:ident => $f:path),* $(,)?) => {
        pub fn registry() -> Vec<$crate::ops::Op> {
            vec![$(
                $crate::ops::Op {
                    name: stringify!($name),
                    run: {
                        fn w<'a>(c: &'a mut $crate::Ctx, a: serde_json::Value)
                            -> $crate::ops::OpFuture<'a> {
                            Box::pin($f(c, a))
                        }
                        w
                    },
                }
            ),*]
        }
    };
}
