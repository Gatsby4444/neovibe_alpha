package com.neovibe.neovibe

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * L'enregistreur des **messages vocaux** (demande de Jay du 2026-09-13).
 *
 * Un seul micro, un seul enregistrement à la fois : `start` refuse si un
 * autre est en cours. Le fichier produit est un `.m4a` (AAC dans un conteneur
 * MPEG-4) — le même conteneur que les vidéos, donc **le même lecteur natif**
 * sait le lire une fois scellé. Aucun format à ajouter au format `NVC1`.
 *
 * ## Ce que ce fichier fait, et ce qu'il ne fait pas
 *
 * Il **capture** et rend un chemin + une durée. Il ne scelle pas, n'envoie
 * pas, ne décide pas à qui : c'est la cuisine (règle de `CLAUDE.md`). Le Dart
 * scelle le fichier, le dépose, puis **supprime le clair** — le clair ne vit
 * que le temps de l'envoi, comme la capture vidéo.
 *
 * ## Réglages
 *
 * Voix : mono, 24 kHz, 32 kbit/s. Un vocal de deux minutes pèse ~480 Ko —
 * c'est ce qui rend la réception sur réseau mobile instantanée, et le cache
 * de 24 h négligeable.
 *
 * ## ⚠️ Permission
 *
 * `RECORD_AUDIO` est déjà au manifeste (caméra). Le Dart la demande AVANT
 * d'appeler `start` ; ici on ne fait que constater l'échec de `MediaRecorder`
 * s'il survient, et le rendre comme une erreur nommée — jamais un fichier
 * vide présenté comme un succès.
 *
 * Volontairement séparé de [NativeCamera] : il ne partage ni son cycle de vie
 * ni ses verrous, et surtout pas son encodeur audio ([DualAudioEncoder]), qui
 * est écrit pour deux muxers vidéo.
 */
class NativeVoiceRecorder(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/voice")

    private var recorder: MediaRecorder? = null
    private var target: File? = null
    private var startedAt = 0L

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val path = call.argument<String>("path")
                        ?: return result.error("ARG", "path manquant", null)
                    if (recorder != null) {
                        return result.error("BUSY", "un enregistrement est déjà en cours", null)
                    }
                    start(File(path))
                    result.success(null)
                }

                "stop" -> {
                    val r = recorder
                        ?: return result.error("IDLE", "aucun enregistrement en cours", null)
                    val durationMs = SystemClock.elapsedRealtime() - startedAt
                    val file = target
                    // ⚠️ `stop()` lève si rien n'a été écrit (enregistrement
                    // trop court) : on rend alors une erreur nommée, et on
                    // nettoie — jamais un fichier vide comme succès.
                    try {
                        r.stop()
                    } catch (e: RuntimeException) {
                        release()
                        file?.delete()
                        return result.error("TOO_SHORT", "enregistrement trop court", null)
                    }
                    release()
                    if (file == null || !file.exists() || file.length() == 0L) {
                        file?.delete()
                        return result.error("EMPTY", "aucun son enregistré", null)
                    }
                    result.success(mapOf("path" to file.path, "durationMs" to durationMs))
                }

                "cancel" -> {
                    val file = target
                    runCatching { recorder?.stop() }
                    release()
                    file?.delete()
                    result.success(null)
                }

                // L'amplitude de l'instant, 0..32767 : de quoi dessiner une
                // onde qui bouge pendant qu'on parle. Lue par le Dart à sa
                // cadence, jamais poussée : c'est lui qui décide du rythme
                // (dissociation acquisition / usage).
                "amplitude" -> {
                    val r = recorder
                    result.success(if (r == null) 0 else runCatching { r.maxAmplitude }.getOrDefault(0))
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            release()
            target?.delete()
            result.error("RECORD_FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun start(file: File) {
        file.parentFile?.mkdirs()
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            MediaRecorder()
        }
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setAudioChannels(1)
        r.setAudioSamplingRate(24_000)
        r.setAudioEncodingBitRate(32_000)
        r.setOutputFile(file.path)
        r.prepare()
        r.start()
        recorder = r
        target = file
        startedAt = SystemClock.elapsedRealtime()
    }

    private fun release() {
        runCatching { recorder?.release() }
        recorder = null
        target = null
    }

    /** Un enregistrement en cours meurt avec l'activité : le fichier aussi. */
    fun dispose() {
        val file = target
        runCatching { recorder?.stop() }
        release()
        file?.delete()
        channel.setMethodCallHandler(null)
    }
}
