package com.neovibe.neovibe.publish

import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.annotations.SerializedName
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * **Le serveur NeoVibe (Rust), vu du natif** (docs/serveur-rust.md) : les
 * gestes de [Remote] et [Distant], par les guichets du serveur.
 *
 * - **Les appels** : `POST <url>/v1/rpc/<nom>`, le badge en `Authorization`,
 *   le même JSON que le Dart. Un refus métier fait **400** avec un `message`
 *   lisible ; un badge périmé fait **401**.
 * - **L'envoi reprenable** : un envoi EN MORCEAUX, droit vers l'entrepôt de
 *   fichiers — `files_upload_open`, puis pour chaque morceau un lien signé
 *   (`files_upload_part_url`) et un `PUT` direct, enfin
 *   `files_upload_finish`, qui assemble. Après une coupure,
 *   `files_upload_parts` dit ce qui est arrivé : on repart du premier morceau
 *   manquant, rien n'est renvoyé deux fois.
 *
 * L'« adresse de reprise » que la file garde ([Remote.tusCreate]) est ici un
 * petit JSON : le coffre, le chemin, l'identifiant de l'envoi.
 */
class RustHttp(private val session: Session) : Distant {

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    private val gson = Gson()

    /** Un envoi en morceaux en cours : de quoi le reprendre. */
    private data class Envoi(
        val bucket: String,
        val path: String,
        @SerializedName("upload_id") val uploadId: String,
    )

    private fun envoi(adresse: String): Envoi = gson.fromJson(adresse, Envoi::class.java)

    private fun json(texte: String): JsonObject = gson.fromJson(texte, JsonObject::class.java)

    /** Un guichet ; lève [AuthExpired] (401), [Rejected] (autre 4xx) ou [IOException]. */
    private fun appel(nom: String, corps: String): String {
        val req = Request.Builder()
            .url("${session.url}/v1/rpc/$nom")
            .header("Authorization", "Bearer ${session.accessToken}")
            .post(corps.toRequestBody(JSON_TYPE))
            .build()
        client.newCall(req).execute().use { r ->
            val texte = runCatching { r.body?.string() ?: "" }.getOrDefault("")
            if (r.isSuccessful) return texte
            if (r.code == 401) throw AuthExpired("$nom : badge refusé (401)")
            val message = runCatching { json(texte).get("message").asString }.getOrNull()
            if (r.code in 400..499) throw Rejected("$nom : ${message ?: "${r.code} ${texte.take(200)}"}")
            throw IOException("$nom : ${r.code} ${texte.take(200)}")
        }
    }

    override fun tusCreate(bucket: String, path: String, size: Long, contentType: String): String {
        val corps = gson.toJson(
            mapOf("bucket" to bucket, "path" to path, "size" to size, "content_type" to contentType),
        )
        val id = json(appel("files_upload_open", corps)).get("upload_id").asString
        return gson.toJson(Envoi(bucket, path, id))
    }

    /** Ce qui est arrivé : les morceaux qui se suivent depuis le premier ; null si l'envoi n'existe plus. */
    override fun tusOffset(uploadUrl: String): Long? {
        val e = envoi(uploadUrl)
        val r = json(appel("files_upload_parts", gson.toJson(e)))
        if (!r.get("known").asBoolean) return null
        val morceaux = r.getAsJsonArray("parts").map { it.asJsonObject }.sortedBy { it.get("number").asInt }
        var attendu = 1
        var offset = 0L
        for (m in morceaux) {
            if (m.get("number").asInt != attendu) break
            offset += m.get("size").asLong
            attendu++
        }
        return offset
    }

    /**
     * Envoie [file] depuis [offset], morceau par morceau, puis fait assembler
     * l'envoi une fois le dernier arrivé ; rend l'offset final. [offset] est
     * toujours une frontière de morceau (ce que rend [tusOffset]).
     */
    override fun tusPatch(
        uploadUrl: String,
        file: File,
        offset: Long,
        onOffset: (Long) -> Unit,
        isCancelled: () -> Boolean,
    ): Long {
        val e = envoi(uploadUrl)
        var at = offset
        val total = file.length()
        RandomAccessFile(file, "r").use { raf ->
            while (at < total) {
                if (isCancelled()) return at
                val len = minOf(CHUNK.toLong(), total - at).toInt()
                val numero = (at / CHUNK).toInt() + 1
                val bytes = ByteArray(len)
                raf.seek(at)
                raf.readFully(bytes)
                val lien = json(
                    appel(
                        "files_upload_part_url",
                        gson.toJson(
                            mapOf("bucket" to e.bucket, "path" to e.path, "upload_id" to e.uploadId, "part_number" to numero),
                        ),
                    ),
                ).get("url").asString
                val put = Request.Builder().url(lien).put(bytes.toRequestBody(OCTETS_TYPE)).build()
                client.newCall(put).execute().use { r ->
                    if (!r.isSuccessful) {
                        if (r.code in 400..499) throw Rejected("envoi du morceau $numero : ${r.code}")
                        throw IOException("envoi du morceau $numero : ${r.code}")
                    }
                }
                at += len
                onOffset(at)
            }
        }
        if (at >= total) appel("files_upload_finish", gson.toJson(e))
        return at
    }

    /** Efface un objet du coffre (annulation) — au mieux, sans lever. */
    override fun deleteObject(bucket: String, path: String) {
        runCatching { appel("files_remove", gson.toJson(mapOf("bucket" to bucket, "paths" to listOf(path)))) }
    }

    override fun rpc(name: String, jsonBody: String) {
        appel(name, jsonBody)
    }

    override fun rpcText(name: String, jsonBody: String): String = appel(name, jsonBody)

    companion object {
        /** La taille d'un morceau : 6 Mo (le minimum de l'entrepôt est 5 Mo, sauf le dernier). */
        const val CHUNK = 6 * 1024 * 1024
        private val JSON_TYPE = "application/json".toMediaType()
        private val OCTETS_TYPE = "application/octet-stream".toMediaType()
    }
}
