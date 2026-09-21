package com.neovibe.neovibe.publish

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Base64
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/**
 * **Le jeton n'est plus bon** : le serveur a répondu 401, ou le coffre a
 * refusé le JWT. Le service demande alors un jeton frais à l'app et attend —
 * il ne se réessaie pas tout seul (voir [SessionStore]).
 */
class AuthExpired(message: String) : IOException(message)

/**
 * **Une erreur qui ne se réessaiera pas d'elle-même** : le serveur a
 * compris la requête et l'a refusée (4xx hors jeton). Un délai n'y changera
 * rien ; c'est l'utilisateur qui décide (réessayer, abandonner).
 */
class Rejected(message: String) : IOException(message)

/** Ce que la file demande au serveur — une interface, pour être éprouvée sans réseau. */
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

/**
 * Les deux appels serveur de la file de publication, en HTTP direct.
 *
 * ## L'envoi reprenable (TUS) — sondé sur le projet de dev le 2026-09-19
 *
 * - `POST /storage/v1/upload/resumable` avec `Upload-Length` et
 *   `Upload-Metadata` (bucket, chemin, type — en base64) → **201** et une
 *   `Location` absolue, valable 24 h ;
 * - `HEAD <Location>` → `Upload-Offset` : ce que le serveur a déjà ;
 * - `PATCH <Location>` par blocs de **6 Mo exactement** (le dernier plus
 *   court), `Upload-Offset` posé → **204** et le nouvel offset.
 *
 * Après une coupure, on refait `HEAD` et on repart de l'offset rendu : rien
 * de ce qui est arrivé n'est renvoyé. C'est ce qui manquait à `upload(File)`,
 * qui recommençait tout à zéro à la moindre coupure.
 *
 * ⚠️ Un JWT invalide côté coffre ne fait pas 401 mais **400** avec
 * `"statusCode":"403"` dans le corps (constaté) : on lit le corps.
 *
 * ## L'inscription (PostgREST)
 *
 * `POST /rest/v1/rpc/publish_to_library` avec le même JSON que le Dart. Un
 * refus métier fait **400** avec un `message` lisible (« Une publication
 * contient de 1 à 20 médias ») ; un jeton faux fait **401** `PGRST301`.
 */
class SupabaseHttp(private val session: Session) : Remote {

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    private fun Request.Builder.auth(): Request.Builder = this
        .header("apikey", session.anonKey)
        .header("Authorization", "Bearer ${session.accessToken}")

    private fun Response.bodyText(): String = runCatching { body?.string() ?: "" }.getOrDefault("")

    /** Range une réponse HTTP en : ok / jeton périmé / refus définitif / à réessayer. */
    private fun check(r: Response, what: String): Response {
        if (r.isSuccessful) return r
        val text = r.bodyText()
        val authy = r.code == 401 ||
            ((r.code == 400 || r.code == 403) &&
                (text.contains("JWS") || text.contains("jwt", ignoreCase = true) ||
                    text.contains("AccessDenied") || text.contains("expired", ignoreCase = true)))
        r.close()
        if (authy) throw AuthExpired("$what : jeton refusé (${r.code})")
        if (r.code in 400..499) throw Rejected("$what : ${message(text, r.code)}")
        throw IOException("$what : ${r.code} ${text.take(200)}")
    }

    private fun message(body: String, code: Int): String {
        val m = Regex("\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"").find(body)
        return m?.groupValues?.get(1)?.replace("\\\"", "\"") ?: "$code ${body.take(200)}"
    }

    // ------------------------------------------------------------------
    // TUS
    // ------------------------------------------------------------------

    /** Ouvre une session d'envoi ; rend son URL de reprise. */
    override fun tusCreate(bucket: String, path: String, size: Long, contentType: String): String {
        fun b64(s: String) = Base64.getEncoder().encodeToString(s.toByteArray())
        val meta = listOf(
            "bucketName ${b64(bucket)}",
            "objectName ${b64(path)}",
            "contentType ${b64(contentType)}",
            "cacheControl ${b64("3600")}",
        ).joinToString(",")
        val req = Request.Builder()
            .url("${session.url}/storage/v1/upload/resumable")
            .auth()
            .header("Tus-Resumable", "1.0.0")
            .header("Upload-Length", size.toString())
            .header("Upload-Metadata", meta)
            .header("x-upsert", "true")
            .post(ByteArray(0).toRequestBody(null))
            .build()
        client.newCall(req).execute().use { r ->
            check(r, "ouverture de l'envoi")
            val location = r.header("Location") ?: throw IOException("ouverture de l'envoi : pas de Location")
            return if (location.startsWith("/")) session.url + location else location
        }
    }

    /** Ce que le serveur a déjà de cet envoi, ou null si la session n'existe plus. */
    override fun tusOffset(uploadUrl: String): Long? {
        val req = Request.Builder().url(uploadUrl).auth().header("Tus-Resumable", "1.0.0").head().build()
        client.newCall(req).execute().use { r ->
            if (r.code == 404 || r.code == 410) return null
            check(r, "reprise de l'envoi")
            return r.header("Upload-Offset")?.toLongOrNull() ?: throw IOException("reprise : pas d'offset")
        }
    }

    /**
     * Envoie [file] depuis [offset], bloc par bloc, et rend l'offset final.
     * [onOffset] est appelé après chaque bloc accepté (pour la progression
     * et pour noter la reprise) ; [isCancelled] est relu entre deux blocs.
     */
    override fun tusPatch(
        uploadUrl: String,
        file: File,
        offset: Long,
        onOffset: (Long) -> Unit,
        isCancelled: () -> Boolean,
    ): Long {
        var at = offset
        val total = file.length()
        RandomAccessFile(file, "r").use { raf ->
            while (at < total) {
                if (isCancelled()) return at
                val len = minOf(CHUNK.toLong(), total - at).toInt()
                val bytes = ByteArray(len)
                raf.seek(at)
                raf.readFully(bytes)
                val req = Request.Builder()
                    .url(uploadUrl)
                    .auth()
                    .header("Tus-Resumable", "1.0.0")
                    .header("Upload-Offset", at.toString())
                    .patch(bytes.toRequestBody(OFFSET_TYPE))
                    .build()
                client.newCall(req).execute().use { r ->
                    check(r, "envoi")
                    at = r.header("Upload-Offset")?.toLongOrNull() ?: (at + len)
                }
                onOffset(at)
            }
        }
        return at
    }

    /** Efface un objet du coffre (annulation) — au mieux, sans lever. */
    override fun deleteObject(bucket: String, path: String) {
        runCatching {
            val req = Request.Builder().url("${session.url}/storage/v1/object/$bucket/$path").auth().delete().build()
            client.newCall(req).execute().close()
        }
    }

    // ------------------------------------------------------------------
    // PostgREST
    // ------------------------------------------------------------------

    /** Appelle une fonction SQL ; lève [AuthExpired], [Rejected] ou [IOException]. */
    override fun rpc(name: String, jsonBody: String) {
        val req = Request.Builder()
            .url("${session.url}/rest/v1/rpc/$name")
            .auth()
            .header("Prefer", "return=minimal")
            .post(jsonBody.toRequestBody(JSON_TYPE))
            .build()
        client.newCall(req).execute().use { r -> check(r, "inscription") }
    }

    /**
     * Un appel RPC dont on lit la réponse (`report_event_position` rend
     * `present` / `away` / `none`, 2026-09-21). Mêmes trois sortes d'erreurs.
     */
    fun rpcText(name: String, jsonBody: String): String {
        val req = Request.Builder()
            .url("${session.url}/rest/v1/rpc/$name")
            .auth()
            .post(jsonBody.toRequestBody(JSON_TYPE))
            .build()
        client.newCall(req).execute().use { r -> return check(r, name).bodyText() }
    }

    companion object {
        /** Supabase exige des blocs de 6 Mo exactement, sauf le dernier. */
        const val CHUNK = 6 * 1024 * 1024
        private val OFFSET_TYPE = "application/offset+octet-stream".toMediaType()
        private val JSON_TYPE = "application/json".toMediaType()
    }
}
