package com.neovibe.neovibe

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Utilitaires média hors caméra.
 *
 * Aujourd'hui, une seule capacité : extraire une **image de couverture** d'un
 * fichier vidéo local, pour que les vignettes des grilles ne soient plus une
 * icône grise (consigne Jay 2026-07-25). Décoder une vidéo comme une image côté
 * Dart lève « Invalid image data » : seul le natif sait lire une frame.
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
                if (source == null || dest == null) {
                    result.error("BAD_ARGS", "source et dest sont requis", null)
                    return
                }
                worker.execute {
                    val error = extract(source, dest, width)
                    // La réponse d'un MethodChannel DOIT partir du thread principal.
                    main.post {
                        if (error == null) result.success(dest)
                        else result.error("THUMB_FAILED", error, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** @return null si l'image a été écrite, sinon le message d'erreur. */
    private fun extract(source: String, dest: String, width: Int): String? {
        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        var scaled: Bitmap? = null
        return try {
            retriever.setDataSource(source)
            // OPTION_CLOSEST_SYNC à t=0 : la première image-clé, la moins chère
            // à décoder. La frame est renvoyée déjà orientée selon la rotation
            // déclarée dans le fichier.
            frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return "aucune image décodable"
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
            if (!tmp.renameTo(file)) return "renommage impossible"
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
