package com.neovibe.neovibe

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Ce qu'il faut savoir de l'appareil pour interpréter un relevé.
 *
 * ### Pourquoi ça vient du natif
 *
 * La version de l'app est écrite dans `pubspec.yaml`, mais **Flutter ne
 * l'expose pas au Dart**. La recopier dans une constante Dart créerait une
 * seconde source de vérité à tenir à jour à la main — et un numéro de version
 * faux dans un rapport de diagnostic est pire que pas de numéro du tout : il
 * fait chercher un bug dans la mauvaise version.
 *
 * Ici, elle est lue dans le paquet installé, c'est-à-dire dans le produit du
 * build lui-même. Elle ne peut pas dériver.
 *
 * Le modèle d'appareil et la version d'Android sont là pour la même raison :
 * le double flux caméra, les décodeurs matériels et la vitesse AES en dépendent
 * tous, et NeoVibe n'est testée que sur un seul téléphone (voir `RAPPELS.md`,
 * avant-prod #8).
 */
class NativeDiagnostics(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/diag")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "deviceInfo") {
            result.notImplemented()
            return
        }
        val info = try {
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (_: Exception) {
            null
        }
        // L'espace libre du volume de l'app (2026-09-19) : un rendu vidéo a
        // disparu du cache en plein travail ; sans ce chiffre, on ne peut pas
        // dire si le système manquait de place.
        val stat = runCatching { android.os.StatFs(context.filesDir.path) }.getOrNull()
        val mem = android.app.ActivityManager.MemoryInfo().also {
            (context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager)
                .getMemoryInfo(it)
        }
        result.success(
            mapOf(
                "appVersion" to (info?.versionName ?: "?"),
                "appBuild" to (info?.longVersionCode?.toString() ?: "?"),
                "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                "android" to "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                "diskFreeBytes" to (stat?.availableBytes ?: -1L),
                "diskTotalBytes" to (stat?.totalBytes ?: -1L),
                "memAvailBytes" to mem.availMem,
                "memTotalBytes" to mem.totalMem,
                "memLow" to mem.lowMemory,
            ),
        )
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
