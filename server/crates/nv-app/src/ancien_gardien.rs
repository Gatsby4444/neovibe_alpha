//! L'ANCIEN GARDIEN : les déclencheurs SQL qui portaient des règles du
//! produit du temps de Supabase, et que le serveur Rust tient désormais
//! lui-même.
//!
//! **Dans une base EN SERVICE, il n'existe plus** : la migration « en
//! service » `migrations_en_service/20260929120000_retrait_de_l_ancien_gardien.sql`
//! l'a retiré (déclencheurs, fonctions, règles RLS, imitations de Supabase),
//! une fois, sur le VPS (deployer.sh) et sur la base du serveur du PC
//! (base_locale.py --serveur). D'où la règle, énoncée
//! positivement : **le serveur ne démarre que si aucun de ces déclencheurs
//! n'existe** ([`encore_presents`], appelé au démarrage). Histoire : le
//! 2026-09-29, allumés à côté du serveur, ils refaisaient son travail — la
//! rencontre au ping était notée deux fois (relevé par le verificateur-base
//! sur le VPS) ; éteints d'abord, ils ont été retirés le même jour.
//!
//! **La base de RÉFÉRENCE de la preuve (nv-proof) les garde**, comme étalon :
//! la preuve joue l'ancien côté avec eux, le nouveau sans eux — d'où cette
//! liste, lue par la preuve et par le serveur.
//!
//! Ne sont PAS dans cette liste les **fondations**, qui restent dans la base
//! parce qu'elles doivent voir tous les chemins, effacements en cascade
//! compris (docs/serveur-rust.md) : l'horodatage des profils
//! (`profiles_updated_at`), les pierres tombales des fichiers
//! (`*_octets_a_supprimer`, `events_affiche_au_balai`), l'annonce des
//! disparitions (`*_annonce_disparition`), l'activité des conversations
//! (`messages_activity`), la libération des preuves (`*_libere`), et les
//! annonces du direct (`zz_nv_direct`).
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

/// Ceux qui existent encore dans la base, allumés ou non (vide : le serveur
/// peut démarrer).
pub async fn encore_presents(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    let mut presents = Vec::new();
    for (table, declencheur) in DECLENCHEURS_DU_GARDIEN {
        let existe: bool = sqlx::query_scalar(
            "select exists (select 1 from pg_trigger where tgrelid = to_regclass($1) and tgname = $2)",
        )
        .bind(table)
        .bind(declencheur)
        .fetch_one(pool)
        .await?;
        if existe {
            presents.push(format!("{table}.{declencheur}"));
        }
    }
    Ok(presents)
}
