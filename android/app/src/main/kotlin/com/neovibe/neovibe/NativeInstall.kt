package com.neovibe.neovibe

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Lance l'installation d'un APK téléchargé.
 *
 * ⚠️ **OUTIL DE DÉVELOPPEMENT.** À retirer avec la section Développeur avant la
 * prod, **avec la permission `REQUEST_INSTALL_PACKAGES` du manifeste** — Google
 * Play la restreint fortement et exige une justification pour la conserver.
 *
 * ## Ce que ce fichier ne peut pas faire
 *
 * Il ne peut **pas** installer silencieusement. Android affiche toujours sa
 * propre demande de confirmation ; seule une application propriétaire de
 * l'appareil (mode kiosque, MDM) y échappe. Ce fichier supprime les gestes
 * *avant* la confirmation, pas la confirmation.
 *
 * ## Le `FileProvider`, et pourquoi on ne peut pas s'en passer
 *
 * Depuis Android 7, passer une `file://` à une autre application lève
 * `FileUriExposedException`. Il faut donc publier le fichier par un
 * `FileProvider` et accorder une permission de lecture temporaire à
 * l'installateur — c'est l'objet de `FLAG_GRANT_READ_URI_PERMISSION`.
 */
class NativeInstall(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/install")

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "install") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("ARG", "chemin manquant", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("NO_FILE", "Fichier introuvable : $path", null)
            return
        }

        try {
            // Android 8+ : l'autorisation d'installer des paquets se demande
            // par application. Sans ce détour, l'intention d'installation est
            // refusée SANS message, et l'utilisateur voit simplement... rien.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !activity.packageManager.canRequestPackageInstalls()
            ) {
                activity.startActivity(
                    Intent(
                        android.provider.Settings
                            .ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}"),
                    ),
                )
                result.error(
                    "NEEDS_PERMISSION",
                    "Autorise NeoVibe à installer des applications, puis " +
                        "relance la mise à jour.",
                    null,
                )
                return
            }

            val uri: Uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.updates",
                file,
            )
            activity.startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message ?: e.toString(), null)
        }
    }
}
