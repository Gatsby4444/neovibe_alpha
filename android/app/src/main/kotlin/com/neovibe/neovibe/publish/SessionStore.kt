package com.neovibe.neovibe.publish

import android.content.Context
import com.google.gson.Gson
import java.io.File

/**
 * **Ce que le service sait de la session** : l'adresse du serveur et le
 * jeton d'accès (le badge) de l'utilisateur — déposés par le Dart à chaque
 * connexion et à chaque renouvellement.
 *
 * ⚠️ **Le service ne renouvelle JAMAIS le jeton lui-même.** Le jeton de
 * renouvellement est à usage unique : l'employer d'ici invaliderait celui de
 * l'app, et l'utilisateur se retrouverait déconnecté. Quand le serveur répond
 * 401, le service demande un jeton frais à l'app ([PublishHub.needToken]) et
 * attend ; si l'app n'est pas là, la publication attend son prochain
 * lancement — c'est la limite assumée de « survit à la fermeture ».
 *
 * Fichier à part de `job.json` : une session vit et meurt avec la connexion,
 * une publication avec son envoi (règle 2 de `CLAUDE.md`).
 */
/**
 * Un fichier écrit avant le retrait de l'ancien serveur (2026-09-29) porte
 * encore `anonKey` et `serveur` : Gson ignore ces clés en trop. Son jeton,
 * s'il venait de l'ancien serveur, est refusé (401) et le service en
 * redemande un à l'app ([AuthExpired]).
 */
data class Session(
    val url: String,
    val accessToken: String,
)

class SessionStore(private val file: File) {

    constructor(context: Context) : this(File(context.filesDir, "publish_session.json"))

    @Volatile
    private var cached: Session? = null

    fun read(): Session? = cached ?: runCatching {
        if (!file.exists()) null else Gson().fromJson(file.readText(), Session::class.java)
    }.getOrNull().also { cached = it }

    @Synchronized
    fun write(session: Session) {
        cached = session
        val tmp = File(file.path + ".tmp")
        tmp.writeText(Gson().toJson(session))
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
    }

    @Synchronized
    fun clear() {
        cached = null
        file.delete()
    }
}
