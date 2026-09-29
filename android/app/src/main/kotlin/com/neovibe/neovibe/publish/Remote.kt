package com.neovibe.neovibe.publish

import java.io.File
import java.io.IOException

// Ces trois types vivaient dans `SupabaseHttp.kt` (le client de l'ancien
// serveur), alors que le client du serveur Rust (`RustHttp`), la file de
// publication et la présence en soirée s'en servent : sortis ici le
// 2026-09-29, quand `SupabaseHttp.kt` a été retiré (inventaire du
// cartographe — le supprimer tel quel cassait la construction).

/**
 * **Le jeton n'est plus bon** : le serveur a répondu 401, ou le coffre a
 * refusé le jeton. Le service demande alors un jeton frais à l'app et attend —
 * il ne se réessaie pas tout seul (voir [SessionStore]).
 */
class AuthExpired(message: String) : IOException(message)

/**
 * **Une erreur qui ne se réessaiera pas d'elle-même** : le serveur a
 * compris la requête et l'a refusée (4xx hors jeton). Un délai n'y changera
 * rien ; c'est l'utilisateur qui décide (réessayer, abandonner).
 */
class Rejected(message: String) : IOException(message)

/**
 * Ce que la file demande au serveur — une interface, pour être éprouvée sans
 * réseau. (Les noms `tus*` viennent du premier serveur, qui envoyait par le
 * protocole TUS ; le serveur Rust y répond par l'envoi en morceaux de
 * l'entrepôt S3 — `RustHttp`.)
 */
interface Remote {
    fun tusCreate(bucket: String, path: String, size: Long, contentType: String): String
    fun tusOffset(uploadUrl: String): Long?
    fun tusPatch(
        uploadUrl: String,
        file: File,
        offset: Long,
        onOffset: (Long) -> Unit,
        isCancelled: () -> Boolean,
    ): Long
    fun deleteObject(bucket: String, path: String)
    fun rpc(name: String, jsonBody: String)
}
