//! **Le direct** — les règles : qui peut suivre quoi, et quelles lignes il
//! reçoit.
//!
//! L'app suit en direct dix tables, chacune avec un filtre éventuel (le même
//! que ses anciens `.stream()` et `onPostgresChanges`). Un **sujet** s'écrit
//! `table` ou `table:colonne=valeur` (ex. `messages:conversation_id=…`).
//!
//! Chaque ligne envoyée passe la règle de lecture de sa table — la
//! traduction de la politique `SELECT` de l'ancienne base, écrite ici une
//! seule fois et servant à la fois à l'**instantané** (l'état au moment de
//! l'abonnement) et à chaque **changement**.
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::args::parse;
use nv_core::{ops, Ctx, NvError, NvResult};

use crate::acces::{q, vrai, P};

ops![direct_instantane => direct_instantane];

/// Les tables suivies en direct.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Table {
    CardDeliveries,
    ConnectionRequests,
    Connections,
    EventChallenges,
    EventGroupMembers,
    EventPresences,
    LibraryItems,
    LocationRequests,
    Messages,
    Removals,
}

impl Table {
    pub const TOUTES: [Table; 10] = [
        Table::CardDeliveries,
        Table::ConnectionRequests,
        Table::Connections,
        Table::EventChallenges,
        Table::EventGroupMembers,
        Table::EventPresences,
        Table::LibraryItems,
        Table::LocationRequests,
        Table::Messages,
        Table::Removals,
    ];

    pub fn nom(&self) -> &'static str {
        match self {
            Table::CardDeliveries => "card_deliveries",
            Table::ConnectionRequests => "connection_requests",
            Table::Connections => "connections",
            Table::EventChallenges => "event_challenges",
            Table::EventGroupMembers => "event_group_members",
            Table::EventPresences => "event_presences",
            Table::LibraryItems => "library_items",
            Table::LocationRequests => "location_requests",
            Table::Messages => "messages",
            Table::Removals => "removals",
        }
    }

    pub fn depuis(nom: &str) -> Option<Table> {
        Table::TOUTES.into_iter().find(|t| t.nom() == nom)
    }

    /// La clé d'une ligne (ce qui l'identifie dans la liste de l'app).
    pub fn cle(&self) -> &'static [&'static str] {
        match self {
            Table::EventGroupMembers => &["event_id", "user_id"],
            _ => &["id"],
        }
    }

    /// Les filtres que l'app emploie, table par table.
    fn filtres(&self) -> &'static [&'static str] {
        match self {
            Table::CardDeliveries => &["recipient_id"],
            Table::ConnectionRequests => &["receiver_id", "sender_id"],
            Table::EventChallenges => &["event_id"],
            Table::EventPresences => &["user_id", "event_id"],
            Table::LocationRequests => &["target_id"],
            Table::Messages => &["conversation_id"],
            Table::Removals => &["conversation_id"],
            Table::Connections | Table::EventGroupMembers | Table::LibraryItems => &[],
        }
    }

    /// **La règle de lecture** de la table (l'ancienne politique `SELECT`),
    /// pour la ligne d'alias `r` et le compte `uid`.
    pub fn visible(&self, r: &str, uid: &str) -> String {
        match self {
            Table::CardDeliveries => format!("({r}.recipient_id = {uid} or {})", q::possede_carte(&format!("{r}.card_id"), uid)),
            Table::ConnectionRequests => format!("({uid} = {r}.sender_id or {uid} = {r}.receiver_id)"),
            Table::Connections => format!("({uid} = {r}.user_low or {uid} = {r}.user_high)"),
            Table::EventChallenges => q::concerne_evenement(&format!("{r}.event_id"), uid),
            Table::EventGroupMembers => q::membre_evenement(&format!("{r}.event_id"), uid),
            Table::EventPresences => {
                format!("({r}.user_id = {uid} or {})", q::concerne_evenement(&format!("{r}.event_id"), uid))
            }
            Table::LibraryItems => q::audience_publication(&format!("{r}.id"), uid),
            Table::LocationRequests => format!("({uid} = {r}.requester_id or {uid} = {r}.target_id)"),
            Table::Messages => format!(
                "({membre} and {r}.expires_at > now() \
                 and {r}.created_at >= (select dm_j.joined_at from public.conversation_members dm_j \
                                        where dm_j.conversation_id = {r}.conversation_id and dm_j.user_id = {uid}) \
                 and not exists (select 1 from public.hidden_messages dm_h where dm_h.message_id = {r}.id and dm_h.user_id = {uid}))",
                membre = q::membre_conversation(&format!("{r}.conversation_id"), uid)
            ),
            Table::Removals => q::membre_conversation(&format!("{r}.conversation_id"), uid),
        }
    }
}

/// Un sujet suivi : une table, et un filtre éventuel.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Sujet {
    pub table: Table,
    pub filtre: Option<(&'static str, Uuid)>,
}

impl Sujet {
    /// Lit `table` ou `table:colonne=valeur`.
    pub fn lire(texte: &str) -> NvResult<Sujet> {
        let (t, f) = match texte.split_once(':') {
            Some((t, f)) => (t, Some(f)),
            None => (texte, None),
        };
        let table = Table::depuis(t).ok_or_else(|| NvError::BadArgs(format!("table non suivie : {t}")))?;
        let filtre = match f {
            None => None,
            Some(f) => {
                let (col, val) = f.split_once('=').ok_or_else(|| NvError::BadArgs("filtre attendu : colonne=valeur".into()))?;
                let col = table
                    .filtres()
                    .iter()
                    .find(|c| **c == col)
                    .ok_or_else(|| NvError::BadArgs(format!("filtre non permis : {col}")))?;
                let val = Uuid::parse_str(val).map_err(|_| NvError::BadArgs("valeur de filtre : un identifiant".into()))?;
                Some((*col, val))
            }
        };
        Ok(Sujet { table, filtre })
    }

    /// La ligne (un objet JSON) correspond-elle au filtre ?
    pub fn correspond(&self, ligne: &Value) -> bool {
        match self.filtre {
            None => true,
            Some((col, val)) => ligne.get(col).and_then(Value::as_str) == Some(val.to_string().as_str()),
        }
    }
}

/// Qui peut s'abonner à un sujet. Un filtre sur « moi » doit être moi ; un
/// filtre sur une conversation ou une soirée exige d'en être.
pub async fn autoriser(db: &mut PgConnection, moi: Uuid, s: &Sujet) -> NvResult<()> {
    let permis = match s.filtre {
        None => true,
        Some(("recipient_id" | "receiver_id" | "sender_id" | "target_id" | "user_id", v)) => v == moi,
        Some(("conversation_id", c)) => {
            vrai(db, &q::membre_conversation("$1::uuid", "$2::uuid"), &[P::U(c), P::U(moi)]).await?
        }
        Some(("event_id", e)) => vrai(db, &q::concerne_evenement("$1::uuid", "$2::uuid"), &[P::U(e), P::U(moi)]).await?,
        Some(_) => false,
    };
    if !permis {
        return Err(NvError::Forbidden);
    }
    Ok(())
}

/// L'état d'un sujet au moment de l'abonnement : les lignes qui passent le
/// filtre ET la règle de lecture, triées par clé.
pub async fn instantane(db: &mut PgConnection, moi: Uuid, s: &Sujet) -> NvResult<Value> {
    let t = s.table;
    let ordre = t.cle().iter().map(|c| format!("r.{c}")).collect::<Vec<_>>().join(", ");
    let (filtre, val) = match s.filtre {
        Some((col, v)) => (format!("r.{col} = $2::uuid"), v),
        None => ("$2::uuid is not null".to_string(), moi),
    };
    let sql = format!(
        "select coalesce(json_agg(r order by {ordre}), '[]'::json) from public.{} r where {filtre} and {}",
        t.nom(),
        t.visible("r", "$1::uuid")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(val).fetch_one(db).await?)
}

/// Une ligne changée (repérée par sa clé), si `moi` a le droit de la voir.
pub async fn ligne_visible(db: &mut PgConnection, moi: Uuid, t: Table, cle: &Value) -> NvResult<Option<Value>> {
    let mut conditions = Vec::new();
    let mut valeurs = Vec::new();
    for (i, c) in t.cle().iter().enumerate() {
        conditions.push(format!("r.{c} = ${}::uuid", i + 2));
        let v = cle.get(*c).and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok());
        let Some(v) = v else {
            // `removals.id` est un compteur, pas un identifiant.
            if let Some(n) = cle.get(*c).and_then(Value::as_i64) {
                let sql = format!(
                    "select to_json(r) from public.{} r where r.{c} = $2 and {}",
                    t.nom(),
                    t.visible("r", "$1::uuid")
                );
                return Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).bind(n).fetch_optional(db).await?);
            }
            return Ok(None);
        };
        valeurs.push(v);
    }
    let sql = format!(
        "select to_json(r) from public.{} r where {} and {}",
        t.nom(),
        conditions.join(" and "),
        t.visible("r", "$1::uuid")
    );
    let mut req = sqlx::query_scalar::<_, Value>(&sql).bind(moi);
    for v in valeurs {
        req = req.bind(v);
    }
    Ok(req.fetch_optional(db).await?)
}

/// Les diffusions sans stockage (l'indicateur « en train d'écrire ») :
/// `typing:<conversation>`, réservées aux membres.
pub async fn peut_diffuser(db: &mut PgConnection, moi: Uuid, sujet: &str) -> NvResult<bool> {
    let Some(conv) = sujet.strip_prefix("typing:").and_then(|c| Uuid::parse_str(c).ok()) else { return Ok(false) };
    vrai(db, &q::membre_conversation("$1::uuid", "$2::uuid"), &[P::U(conv), P::U(moi)]).await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Instantane {
    sujet: String,
}

/// `direct_instantane(sujet)` : l'état d'un sujet (l'app le lit juste
/// après s'être abonnée, puis applique les changements).
async fn direct_instantane(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = ctx.actor.uid()?;
    let a: Instantane = parse(args)?;
    let s = Sujet::lire(&a.sujet)?;
    autoriser(ctx.db(), moi, &s).await?;
    instantane(ctx.db(), moi, &s).await
}

/// Ce que le direct envoie pour un changement.
pub fn message_changement(reference: &str, op: &str, ligne: Value) -> Value {
    json!({ "type": "changement", "ref": reference, "op": op, "ligne": ligne })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_sujets() -> NvResult<()> {
        let id = Uuid::new_v4();
        let s = Sujet::lire(&format!("messages:conversation_id={id}"))?;
        assert_eq!(s.table, Table::Messages);
        assert!(s.correspond(&json!({ "conversation_id": id.to_string() })));
        assert!(!s.correspond(&json!({ "conversation_id": Uuid::new_v4().to_string() })));
        assert!(Sujet::lire("profiles").is_err(), "une table non suivie");
        assert!(Sujet::lire(&format!("messages:sender_id={id}")).is_err(), "un filtre non permis");
        assert!(Sujet::lire("messages:conversation_id=pas-un-id").is_err());
        assert_eq!(Sujet::lire("connections")?.filtre, None);
        Ok(())
    }
}
