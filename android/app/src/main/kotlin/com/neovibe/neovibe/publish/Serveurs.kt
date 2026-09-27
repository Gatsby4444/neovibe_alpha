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
 * **Le serveur d'une session** : Supabase (l'app de tous les jours) ou le
 * serveur Rust (l'app d'essai, `--dart-define=SERVEUR=rust`,
 * docs/serveur-rust.md étape 11). C'est le Dart qui le dit, en déposant la
 * session ; le natif ne le devine jamais.
 */
object Serveurs {
    fun distant(session: Session): Distant =
        if (session.serveur == "rust") RustHttp(session) else SupabaseHttp(session)
}
