//! L'ANCIEN GARDIEN : les déclencheurs SQL qui portaient des règles du
//! produit du temps de Supabase, et que le serveur Rust tient désormais
//! lui-même.
//!
//! **Le serveur n'est juste qu'avec eux ÉTEINTS** : c'est ainsi que la preuve
//! par comparaison le joue (nv-proof). Allumés à côté de lui, ils refont son
//! travail — et ce qui ne se rejoue pas sans effet se fait deux fois : la
//! rencontre au ping était notée en double dans `meetings` (relevé en base
//! du VPS par le verificateur-base le 2026-09-29, avant la bascule de
//! l'app). D'où la règle, énoncée positivement : **le serveur ne démarre
//! que si chacun d'eux est éteint** ([`encore_allumes`], appelé au
//! démarrage), et l'installation les éteint d'après CETTE liste
//! (`nv-server eteindre-l-ancien-gardien`), la même que celle de la preuve.
//!
//! Ne sont PAS dans cette liste les **fondations**, qui restent dans la base
//! parce qu'elles doivent voir tous les chemins, effacements en cascade
//! compris (docs/serveur-rust.md) : l'horodatage des profils
//! (`profiles_updated_at`), les pierres tombales des fichiers
//! (`*_octets_a_supprimer`, `events_affiche_au_balai`), l'annonce des
//! disparitions (`*_annonce_disparition`), l'activité des conversations
//! (`messages_activity`), la libération des preuves (`*_libere`), et les
//! annonces du direct et de la preuve.
use sqlx::PgPool;

/// `(table, déclencheur)`.
pub const DECLENCHEURS_DU_GARDIEN: &[(&str, &str)] = &[
    ("public.messages", "messages_rules"),
    ("public.card_deliveries", "card_deliveries_rules"),
    ("public.cards", "cards_refuse_si_suspendu"),
    ("public.connection_requests", "connection_requests_refuse_si_suspendu"),
    ("public.content_likes", "content_likes_refuse_si_suspendu"),
    ("public.recommendations", "recommendations_refuse_si_suspendu"),
    ("public.waves", "waves_refuse_si_suspendu"),
    ("public.card_reports", "card_reports_scelle"),
    ("public.content_reports", "content_reports_scelle"),
    ("public.event_reports", "event_reports_scelle"),
    ("public.library_vibe_reports", "library_vibe_reports_scelle"),
    ("public.connections", "connections_delete_oublie"),
    ("public.ping_pairs", "ping_pairs_meeting"),
    ("public.event_crossings", "event_crossings_meeting"),
    ("auth.users", "record_device_signup"),
];

/// Le SQL qui les éteint (à passer en propriétaire des tables : `postgres`).
/// Rejouable. Un déclencheur — ou une table — déjà disparu n'est pas une
/// erreur : c'est l'étape d'après (le retrait de l'ancien gardien).
///
/// ⚠️ Limite, dite : le serveur ne vérifie l'extinction qu'à SON DÉMARRAGE
/// ([`encore_allumes`]). Un déclencheur rallumé pendant qu'il tourne (une
/// migration rejouée, un geste à la main) referait le travail en double
/// jusqu'au redémarrage suivant. La cause disparaîtra avec le RETRAIT de ces
/// déclencheurs de la base de service (RAPPELS #176 ⑩, par le cartographe) ;
/// d'ici là, tout déploiement repasse par ici et redémarre le serveur.
pub fn sql_pour_les_eteindre() -> String {
    DECLENCHEURS_DU_GARDIEN
        .iter()
        .map(|(table, declencheur)| {
            format!(
                "do $$ begin if exists (select 1 from pg_trigger where tgrelid = to_regclass('{table}') and tgname = '{declencheur}') \
                 then alter table {table} disable trigger {declencheur}; end if; end $$;\n"
            )
        })
        .collect()
}

/// Ceux qui sont encore allumés dans la base (vide : le serveur peut
/// démarrer). Un déclencheur disparu compte comme éteint.
pub async fn encore_allumes(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    let mut allumes = Vec::new();
    for (table, declencheur) in DECLENCHEURS_DU_GARDIEN {
        let etat: Option<String> = sqlx::query_scalar(
            "select tgenabled::text from pg_trigger where tgrelid = to_regclass($1) and tgname = $2",
        )
        .bind(table)
        .bind(declencheur)
        .fetch_optional(pool)
        .await?;
        if etat.is_some_and(|e| e != "D") {
            allumes.push(format!("{table}.{declencheur}"));
        }
    }
    Ok(allumes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chaque_declencheur_a_sa_ligne() {
        let sql = sql_pour_les_eteindre();
        assert_eq!(sql.lines().count(), DECLENCHEURS_DU_GARDIEN.len());
        assert!(sql.contains("alter table public.ping_pairs disable trigger ping_pairs_meeting;"));
    }
}
