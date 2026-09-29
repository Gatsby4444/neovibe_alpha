package com.neovibe.neovibe.publish

/**
 * **Ce que le natif demande à un serveur** : la file de publication
 * ([Remote]) et les appels dont on lit la réponse (la balise du ping, la
 * présence en soirée).
 */
interface Distant : Remote {
    /** Un appel dont on lit la réponse (texte JSON) ; mêmes trois sortes d'erreurs. */
    fun rpcText(name: String, jsonBody: String): String
}

/**
 * **Le serveur d'une session** : le serveur Rust (l'app de tous les jours
 * depuis la bascule du 2026-09-29, v0.9.300) ou Supabase (l'ancien serveur,
 * en pause ; `--dart-define=SERVEUR=supabase`). C'est le Dart qui le dit, en
 * déposant la session ; le natif ne le devine jamais.
 */
object Serveurs {
    fun distant(session: Session): Distant =
        if (session.serveur == "rust") RustHttp(session) else SupabaseHttp(session)
}
