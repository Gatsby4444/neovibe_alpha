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
 * **Le serveur d'une session** : le serveur NeoVibe (Rust), à l'adresse
 * que le Dart a déposée avec la session. Depuis le retrait de l'ancien
 * serveur (Supabase, 2026-09-29), il n'y a plus de choix à faire : une seule
 * porte, pour le service de publication, la balise du ping et la présence en
 * soirée.
 */
object Serveurs {
    fun distant(session: Session): Distant = RustHttp(session)
}
