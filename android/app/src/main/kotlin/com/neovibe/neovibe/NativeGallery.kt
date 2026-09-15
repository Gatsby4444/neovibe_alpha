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
 * Trois capacités, toutes en lecture :
 * - `list(offset, limit)` : les médias (images et vidéos) du `MediaStore`, les
 *   plus récents d'abord, avec leur durée et leurs dimensions ;
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

    // Plusieurs vignettes en parallèle : une grille en demande vingt d'un coup.
    private val thumbs = Executors.newFixedThreadPool(3)
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> {
                val offset = call.argument<Int>("offset") ?: 0
                val limit = call.argument<Int>("limit") ?: 60
                worker.execute {
                    val outcome = runCatching { list(offset, limit) }
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

    private fun list(offset: Int, limit: Int): List<Map<String, Any?>> {
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
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        )
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
                val uri = ContentUris.withAppendedId(
                    if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    id,
                )
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

    private fun thumbnail(uri: Uri, size: Int): ByteArray {
        // `loadThumbnail` rend l'image déjà orientée, et met en cache côté
        // système : la deuxième demande de la même vignette est immédiate.
        val bitmap = context.contentResolver.loadThumbnail(uri, Size(size, size), null)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)
        bitmap.recycle()
        return out.toByteArray()
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
