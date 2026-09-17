package com.neovibe.neovibe

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * **La galerie du téléphone, lue par nous** (2026-09-15) — pour que « Nouvelle
 * publication » montre la grille des photos et vidéos DANS l'app, avec un grand
 * aperçu et une sélection numérotée, comme Instagram, au lieu d'envoyer
 * l'utilisateur dans le sélecteur du système.
 *
 * Quatre capacités, toutes en lecture :
 * - `albums()` : les dossiers du téléphone (Camera, Screenshots, WhatsApp…),
 *   avec leur nom, leur nombre de médias et la couverture la plus récente —
 *   « une interface plus complète et pro comme sur Instagram » (Jay,
 *   2026-09-17) ;
 * - `list(offset, limit, bucketId, mediaType)` : les médias (images et
 *   vidéos) du `MediaStore`, les plus récents d'abord, avec leur durée et
 *   leurs dimensions ; filtrables par **dossier** et par **type** ;
 * - `thumbnail(uri, size)` : une vignette JPEG (le système la met en cache,
 *   `ContentResolver.loadThumbnail`, API 29) ;
 * - `copy(uri, dest)` : une copie du fichier dans notre cache, pour l'éditeur.
 *
 * Aucune écriture dans la galerie. La permission (`READ_MEDIA_IMAGES` /
 * `READ_MEDIA_VIDEO`, ou `READ_EXTERNAL_STORAGE` avant Android 13) est
 * demandée côté Dart avant d'appeler ici.
 */
class NativeGallery(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/gallery")

    // Plusieurs vignettes en parallèle : une grille en demande vingt d'un
    // coup, et décoder une vignette est du calcul pur — autant de fils que de
    // cœurs, six au plus (le Dart n'en envoie jamais plus de six à la fois).
    private val thumbs = Executors.newFixedThreadPool(
        Runtime.getRuntime().availableProcessors().coerceIn(2, 6),
    )
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "albums" -> {
                worker.execute {
                    val outcome = runCatching { albums() }
                    main.post {
                        outcome.onSuccess { result.success(it) }
                            .onFailure { result.error("ALBUMS_FAILED", it.message, null) }
                    }
                }
            }
            "list" -> {
                val offset = call.argument<Int>("offset") ?: 0
                val limit = call.argument<Int>("limit") ?: 60
                val bucketId = call.argument<String>("bucketId")
                val mediaType = call.argument<String>("mediaType")
                worker.execute {
                    val outcome = runCatching { list(offset, limit, bucketId, mediaType) }
                    main.post {
                        outcome.onSuccess { result.success(it) }
                            .onFailure { result.error("LIST_FAILED", it.message, null) }
                    }
                }
            }
            "thumbnail" -> {
                val uri = call.argument<String>("uri")
                val size = call.argument<Int>("size") ?: 300
                if (uri == null) {
                    result.error("BAD_ARGS", "uri est requis", null)
                    return
                }
                thumbs.execute {
                    val outcome = runCatching { thumbnail(Uri.parse(uri), size) }
                    main.post {
                        outcome.onSuccess { result.success(it) }
                            .onFailure { result.error("THUMB_FAILED", it.message, null) }
                    }
                }
            }
            "copy" -> {
                val uri = call.argument<String>("uri")
                val dest = call.argument<String>("dest")
                if (uri == null || dest == null) {
                    result.error("BAD_ARGS", "uri et dest sont requis", null)
                    return
                }
                worker.execute {
                    val outcome = runCatching { copy(Uri.parse(uri), File(dest)) }
                    main.post {
                        outcome.onSuccess { result.success(dest) }
                            .onFailure { result.error("COPY_FAILED", it.message, null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * **Les dossiers du téléphone**, les plus récemment nourris d'abord.
     *
     * ⚠️ **Pas de `GROUP BY`** : le `MediaProvider` d'Android le refuse depuis
     * Android 10 (comme il refuse `LIMIT`, voir [list]). On parcourt donc le
     * curseur une fois, trié par date, et on agrège ici : le premier média
     * rencontré d'un dossier est sa couverture (le plus récent), et on compte
     * au passage. Trois colonnes seulement : c'est une lecture d'index, pas
     * un chargement de médias.
     */
    private fun albums(): List<Map<String, Any?>> {
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.BUCKET_ID,
            MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
        )
        val queryArgs = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, MEDIA_SELECTION)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, MEDIA_ARGS)
            putStringArray(
                ContentResolver.QUERY_ARG_SORT_COLUMNS,
                arrayOf(MediaStore.Files.FileColumns.DATE_ADDED),
            )
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
        }
        // L'ordre d'insertion est celui de la date : le premier dossier vu
        // est celui qui a le média le plus récent.
        val parDossier = LinkedHashMap<String, MutableMap<String, Any?>>()
        context.contentResolver.query(collection, projection, queryArgs, null)?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val typeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val bucketCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
            while (c.moveToNext()) {
                if (c.isNull(bucketCol)) continue
                val bucket = c.getString(bucketCol) ?: continue
                val existant = parDossier[bucket]
                if (existant != null) {
                    existant["count"] = (existant["count"] as Int) + 1
                    continue
                }
                val isVideo = c.getInt(typeCol) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                parDossier[bucket] = mutableMapOf(
                    "id" to bucket,
                    "name" to (c.getString(nameCol) ?: "Sans nom"),
                    "count" to 1,
                    "coverUri" to mediaUri(c.getLong(idCol), isVideo).toString(),
                )
            }
        }
        return parDossier.values.toList()
    }

    private fun mediaUri(id: Long, isVideo: Boolean): Uri = ContentUris.withAppendedId(
        if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
        id,
    )

    private fun list(
        offset: Int,
        limit: Int,
        bucketId: String? = null,
        mediaType: String? = null,
    ): List<Map<String, Any?>> {
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.DATE_ADDED,
            MediaStore.Files.FileColumns.DURATION,
            MediaStore.Files.FileColumns.WIDTH,
            MediaStore.Files.FileColumns.HEIGHT,
            MediaStore.Files.FileColumns.MIME_TYPE,
        )
        // Le filtre : le type demandé (les deux par défaut), et le dossier
        // s'il y en a un. Construit ici pour que `list` et `albums` ne
        // puissent pas diverger sur ce qu'est « un média ».
        var selection = when (mediaType) {
            "image" -> "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
            "video" -> "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
            else -> MEDIA_SELECTION
        }
        var args = when (mediaType) {
            "image" -> arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString())
            "video" -> arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString())
            else -> MEDIA_ARGS
        }
        if (bucketId != null) {
            selection += " AND ${MediaStore.Files.FileColumns.BUCKET_ID} = ?"
            args += bucketId
        }
        // ⚠️ Pas de `LIMIT` dans l'ordre de tri : MediaProvider le refuse
        // depuis Android 11 (« Invalid token LIMIT »). La pagination passe par
        // les arguments de requête (API 26+).
        val queryArgs = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
            putStringArray(
                ContentResolver.QUERY_ARG_SORT_COLUMNS,
                arrayOf(MediaStore.Files.FileColumns.DATE_ADDED),
            )
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
        }
        val out = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(collection, projection, queryArgs, null)?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val typeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val dateCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_ADDED)
            val durCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DURATION)
            val wCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.WIDTH)
            val hCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.HEIGHT)
            val mimeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
            while (c.moveToNext()) {
                val id = c.getLong(idCol)
                val isVideo = c.getInt(typeCol) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val uri = mediaUri(id, isVideo)
                out.add(
                    mapOf(
                        "uri" to uri.toString(),
                        "isVideo" to isVideo,
                        "dateAdded" to c.getLong(dateCol),
                        "durationMs" to if (isVideo && !c.isNull(durCol)) c.getLong(durCol).toInt() else null,
                        "width" to if (c.isNull(wCol)) 0 else c.getInt(wCol),
                        "height" to if (c.isNull(hCol)) 0 else c.getInt(hCol),
                        "mime" to c.getString(mimeCol),
                    ),
                )
            }
        }
        return out
    }

    private companion object {
        /** Ce qui compte comme « un média » : une image ou une vidéo. */
        val MEDIA_SELECTION =
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
        val MEDIA_ARGS = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        )
    }

    private fun thumbnail(uri: Uri, size: Int): ByteArray {
        // `loadThumbnail` rend l'image déjà orientée, et met en cache côté
        // système : la deuxième demande de la même vignette est immédiate.
        // ⚠️ Il refuse certains fichiers (formats exotiques, entrées
        // orphelines du MediaStore) : on décode alors nous-mêmes, réduit, au
        // lieu de laisser une case vide — « beaucoup sont noires » (Jay).
        val bitmap = try {
            context.contentResolver.loadThumbnail(uri, Size(size, size), null)
        } catch (e: Exception) {
            fallbackThumbnail(uri, size) ?: throw e
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    /** Une image : décodée réduite (`inSampleSize`) ; une vidéo : sa première image. */
    private fun fallbackThumbnail(uri: Uri, size: Int): Bitmap? {
        val isVideo = uri.toString().contains("/video/")
        if (isVideo) {
            val r = android.media.MediaMetadataRetriever()
            return try {
                r.setDataSource(context, uri)
                r.getFrameAtTime(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } catch (_: Exception) {
                null
            } finally {
                runCatching { r.release() }
            }
        }
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use {
            android.graphics.BitmapFactory.decodeStream(it, null, bounds)
        }
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= size && bounds.outHeight / (sample * 2) >= size) sample *= 2
        val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
        val raw = context.contentResolver.openInputStream(uri)?.use {
            android.graphics.BitmapFactory.decodeStream(it, null, opts)
        } ?: return null
        // L'orientation EXIF, que `loadThumbnail` appliquait pour nous.
        val rotation = runCatching {
            context.contentResolver.openInputStream(uri)?.use { s ->
                when (androidx.exifinterface.media.ExifInterface(s).getAttributeInt(
                    androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION,
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_NORMAL,
                )) {
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } ?: 0f
        }.getOrDefault(0f)
        if (rotation == 0f) return raw
        val m = android.graphics.Matrix().apply { postRotate(rotation) }
        val turned = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
        if (turned !== raw) raw.recycle()
        return turned
    }

    private fun copy(uri: Uri, dest: File) {
        dest.parentFile?.mkdirs()
        val tmp = File(dest.path + ".part")
        context.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(tmp).use { output -> input.copyTo(output) }
        } ?: throw IllegalStateException("fichier illisible")
        if (!tmp.renameTo(dest)) throw IllegalStateException("renommage impossible")
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        thumbs.shutdown()
        worker.shutdown()
    }
}
