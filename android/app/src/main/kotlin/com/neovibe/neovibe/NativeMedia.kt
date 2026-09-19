package com.neovibe.neovibe

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Utilitaires média hors caméra.
 *
 * - `videoThumbnail` : une **image de couverture** d'une vidéo locale, à un
 *   instant donné, pour que les vignettes ne soient pas une icône grise
 *   (consigne Jay 2026-07-25). Décoder une vidéo comme une image côté Dart
 *   lève « Invalid image data » : seul le natif sait lire une frame.
 * - `fastStart` : l'index MP4 en tête de fichier (`Mp4FastStart`).
 * - `probe` : dimensions **après rotation**, durée, nature (photo / vidéo)
 *   d'un fichier de la galerie — sans le décoder (album, 2026-09-15).
 * - `encodeJpeg` : des pixels RGBA rendus par Flutter → un JPEG (l'export
 *   d'une photo d'album ; `dart:ui` ne sait écrire que du PNG).
 * - `transcode` : une vidéo de la galerie rognée, recadrée, corrigée et
 *   recompressée pour un album ([MediaTranscoder]), avec sa progression.
 * - `readAll` : le **clair** d'un média scellé `NVC1` rendu en mémoire (une
 *   photo, une vignette) — jamais sur le disque. Le déchiffrement Dart des
 *   photos tenait ~2,7 Mo/s sur le fil de l'interface : chaque vignette du
 *   profil coûtait ~85 ms d'écran figé, l'une après l'autre (les « roues »
 *   du 2026-09-19).
 * - `seal` : **scelle** un fichier au format `NVC1` ([SealedChunkWriter]) — le
 *   scellage Dart figeait l'écran ~9 s par vidéo de 25 Mo à l'envoi.
 * - `unseal` : le **clair** d'un média scellé `NVC1`, écrit dans un fichier
 *   — ce que « Enregistrer » copie dans les Enregistrements. Le déchiffrement
 *   en Dart plafonnait à ~2,7 Mo/s **sur le fil de l'interface** : un Flow de
 *   36 Mo figeait l'écran treize secondes (Jay, 2026-09-18 : « Sauvegarder
 *   bugue et est lent »). Ici, [SealedChunkReader] passe par les instructions
 *   AES du processeur, sur le fil de travail.
 *
 * Volontairement séparé de [NativeCamera] : ça ne touche pas au matériel, ça ne
 * doit pas partager son cycle de vie ni ses verrous.
 */
class NativeMedia(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/media")

    // L'extraction décode une frame : jamais sur le thread principal.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "videoThumbnail" -> {
                val source = call.argument<String>("source")
                val dest = call.argument<String>("dest")
                val width = call.argument<Int>("width") ?: 480
                val atMs = call.argument<Int>("atMs") ?: 0
                if (source == null || dest == null) {
                    result.error("BAD_ARGS", "source et dest sont requis", null)
                    return
                }
                worker.execute {
                    val error = extract(source, dest, width, atMs)
                    // La réponse d'un MethodChannel DOIT partir du thread principal.
                    main.post {
                        if (error == null) result.success(dest)
                        else result.error("THUMB_FAILED", error, null)
                    }
                }
            }
            "fastStart" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("BAD_ARGS", "path est requis", null)
                    return
                }
                worker.execute {
                    // Réécrit un fichier de plusieurs dizaines de Mo : jamais
                    // sur le thread principal.
                    val outcome = Mp4FastStart.apply(File(path))
                    main.post { result.success(outcome.name) }
                }
            }
            "probe" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("BAD_ARGS", "path est requis", null)
                    return
                }
                worker.execute {
                    val outcome = runCatching { probe(File(path)) }
                    main.post {
                        outcome.onSuccess { result.success(it) }
                            .onFailure { result.error("PROBE_FAILED", it.message, null) }
                    }
                }
            }
            "encodeJpeg" -> {
                val rgba = call.argument<ByteArray>("rgba")
                val width = call.argument<Int>("width")
                val height = call.argument<Int>("height")
                val dest = call.argument<String>("dest")
                val quality = call.argument<Int>("quality") ?: 88
                if (rgba == null || width == null || height == null || dest == null) {
                    result.error("BAD_ARGS", "rgba, width, height et dest sont requis", null)
                    return
                }
                worker.execute {
                    val error = encodeJpeg(rgba, width, height, dest, quality)
                    main.post {
                        if (error == null) result.success(dest)
                        else result.error("JPEG_FAILED", error, null)
                    }
                }
            }
            "transcode" -> {
                val params = runCatching { transcodeParams(call) }.getOrNull()
                val jobId = call.argument<String>("jobId")
                if (params == null || jobId == null) {
                    result.error("BAD_ARGS", "paramètres de transcodage incomplets", null)
                    return
                }
                worker.execute {
                    var lastReported = -1
                    val outcome = MediaTranscoder.run(params) { progress ->
                        // Au plus une notification par pour cent : le canal
                        // n'est pas fait pour trente messages par seconde.
                        val pct = (progress * 100).toInt()
                        if (pct != lastReported) {
                            lastReported = pct
                            main.post {
                                channel.invokeMethod(
                                    "transcodeProgress",
                                    mapOf("jobId" to jobId, "progress" to progress.toDouble()),
                                )
                            }
                        }
                    }
                    main.post {
                        if (outcome.ok) {
                            result.success(
                                mapOf(
                                    "durationMs" to outcome.durationMs,
                                    "hasAudio" to outcome.hasAudio,
                                    "note" to outcome.note,
                                ),
                            )
                        } else {
                            result.error("TRANSCODE_FAILED", outcome.message, outcome.note)
                        }
                    }
                }
            }
            "readAll" -> {
                val sealed = call.argument<String>("sealed")
                val key = call.argument<String>("key")
                if (sealed == null || key == null) {
                    result.error("BAD_ARGS", "sealed et key sont requis", null)
                    return
                }
                worker.execute {
                    val outcome = runCatching { readAll(File(sealed), key) }
                    main.post {
                        outcome.onSuccess { result.success(it) }
                            .onFailure { result.error("READ_FAILED", it.message, null) }
                    }
                }
            }
            "seal" -> {
                val source = call.argument<String>("source")
                val key = call.argument<String>("key")
                val dest = call.argument<String>("dest")
                if (source == null || key == null || dest == null) {
                    result.error("BAD_ARGS", "source, key et dest sont requis", null)
                    return
                }
                worker.execute {
                    val outcome = runCatching { SealedChunkWriter.seal(File(source), File(dest), key) }
                    main.post {
                        outcome.onSuccess { result.success(dest) }
                            .onFailure { result.error("SEAL_FAILED", it.message ?: it.javaClass.simpleName, null) }
                    }
                }
            }
            "unseal" -> {
                val sealed = call.argument<String>("sealed")
                val key = call.argument<String>("key")
                val dest = call.argument<String>("dest")
                if (sealed == null || key == null || dest == null) {
                    result.error("BAD_ARGS", "sealed, key et dest sont requis", null)
                    return
                }
                worker.execute {
                    val error = unseal(File(sealed), key, File(dest))
                    main.post {
                        if (error == null) result.success(dest)
                        else result.error("UNSEAL_FAILED", error, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Le clair de [sealed] en mémoire — réservé aux photos, qui y tiennent. */
    private fun readAll(sealed: File, key: String): ByteArray =
        SealedChunkReader(sealed, key).use { reader ->
            val out = ByteArray(reader.plainLength.toInt())
            var position = 0L
            while (position < reader.plainLength) {
                val n = reader.read(position, out, position.toInt(), (reader.plainLength - position).toInt())
                if (n <= 0) throw IllegalStateException("clair incomplet : $position / ${reader.plainLength}")
                position += n
            }
            out
        }

    /**
     * Écrit dans [dest] le clair de [sealed], bloc par bloc : la mémoire reste
     * bornée à un bloc, quelle que soit la taille de la vidéo. Rend `null` en
     * cas de succès, sinon le message d'erreur — et [dest] est alors effacé :
     * un clair tronqué qui reste sur le disque passerait pour une sauvegarde.
     */
    private fun unseal(sealed: File, key: String, dest: File): String? = try {
        SealedChunkReader(sealed, key).use { reader ->
            FileOutputStream(dest).use { out ->
                val buffer = ByteArray(256 * 1024)
                var position = 0L
                while (position < reader.plainLength) {
                    val n = reader.read(position, buffer, 0, buffer.size)
                    if (n <= 0) break
                    out.write(buffer, 0, n)
                    position += n
                }
                if (position != reader.plainLength) {
                    throw IllegalStateException(
                        "clair incomplet : $position / ${reader.plainLength} octets",
                    )
                }
            }
        }
        null
    } catch (e: Exception) {
        dest.delete()
        e.message ?: e.javaClass.simpleName
    }

    private fun transcodeParams(call: MethodCall): MediaTranscoder.Params {
        fun i(key: String) = call.argument<Int>(key) ?: throw IllegalArgumentException(key)
        val uniforms = call.argument<List<Number>>("uniforms") ?: throw IllegalArgumentException("uniforms")
        if (uniforms.size != 24) throw IllegalArgumentException("uniforms : 24 valeurs attendues")
        val corners = call.argument<List<Number>>("corners") ?: throw IllegalArgumentException("corners")
        if (corners.size != 8) throw IllegalArgumentException("corners : 8 valeurs attendues")
        return MediaTranscoder.Params(
            source = File(call.argument<String>("source") ?: throw IllegalArgumentException("source")),
            dest = File(call.argument<String>("dest") ?: throw IllegalArgumentException("dest")),
            startMs = i("startMs"),
            endMs = i("endMs"),
            corners = FloatArray(8) { corners[it].toFloat() },
            outWidth = i("outWidth"),
            outHeight = i("outHeight"),
            uniforms = FloatArray(24) { uniforms[it].toFloat() },
            overlayPath = call.argument<String>("overlayPath"),
            rotation = i("rotation"),
        )
    }

    /**
     * Ce qu'un fichier de la galerie est, sans le décoder : `isVideo`,
     * `width` / `height` **après rotation** (une photo de téléphone est
     * souvent stockée couchée avec une balise EXIF ; une vidéo porte sa
     * rotation dans le conteneur), `durationMs` (vidéo), `rotation`.
     */
    private fun probe(file: File): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            val hasVideo = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            if (hasVideo) {
                val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toIntOrNull() ?: 0
                val upright = rotation == 90 || rotation == 270
                return mapOf(
                    "isVideo" to true,
                    "width" to if (upright) h else w,
                    "height" to if (upright) w else h,
                    "durationMs" to duration,
                    "rotation" to rotation,
                )
            }
        } catch (_: Exception) {
            // Pas une vidéo lisible : on essaie comme une image.
        } finally {
            runCatching { retriever.release() }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalArgumentException("fichier illisible : ni vidéo ni image")
        }
        val orientation = runCatching {
            ExifInterface(file.path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
            )
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val rotation = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270, ExifInterface.ORIENTATION_TRANSVERSE -> 270
            else -> 0
        }
        val upright = rotation == 90 || rotation == 270
        return mapOf(
            "isVideo" to false,
            "width" to if (upright) bounds.outHeight else bounds.outWidth,
            "height" to if (upright) bounds.outWidth else bounds.outHeight,
            "durationMs" to null,
            "rotation" to rotation,
        )
    }

    /** @return null si le JPEG a été écrit, sinon le message d'erreur. */
    private fun encodeJpeg(rgba: ByteArray, width: Int, height: Int, dest: String, quality: Int): String? {
        if (rgba.size != width * height * 4) return "taille des pixels incohérente"
        var bitmap: Bitmap? = null
        return try {
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
            val file = File(dest)
            file.parentFile?.mkdirs()
            val tmp = File("$dest.part")
            FileOutputStream(tmp).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(50, 100), out)
            }
            MediaTranscoder.moveInto(tmp, file)?.let { return it }
            null
        } catch (e: Exception) {
            e.message ?: e.javaClass.simpleName
        } finally {
            bitmap?.recycle()
        }
    }

    /** @return null si l'image a été écrite, sinon le message d'erreur. */
    private fun extract(source: String, dest: String, width: Int, atMs: Int): String? {
        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        var scaled: Bitmap? = null
        return try {
            retriever.setDataSource(source)
            // À t=0 : OPTION_CLOSEST_SYNC, la première image-clé, la moins chère
            // à décoder. À un autre instant (la couverture choisie d'une vidéo
            // d'album) : OPTION_CLOSEST, l'image exacte, plus coûteuse mais
            // c'est celle que l'utilisateur a désignée. La frame est renvoyée
            // déjà orientée selon la rotation déclarée dans le fichier.
            frame = if (atMs <= 0) {
                retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } else {
                retriever.getFrameAtTime(atMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST)
            } ?: return "aucune image décodable"
            val ratio = frame.height.toFloat() / frame.width.toFloat()
            val target = minOf(width, frame.width)
            scaled = Bitmap.createScaledBitmap(frame, target, (target * ratio).toInt(), true)
            val file = File(dest)
            file.parentFile?.mkdirs()
            // Écriture en deux temps : un fichier partiel ne doit jamais être
            // pris pour une vignette valide si le processus meurt en route.
            val tmp = File("$dest.part")
            FileOutputStream(tmp).use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
            }
            MediaTranscoder.moveInto(tmp, file)?.let { return it }
            null
        } catch (e: Exception) {
            e.message ?: e.javaClass.simpleName
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
            if (scaled !== frame) scaled?.recycle()
            frame?.recycle()
        }
    }
}
