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

    /**
     * Copie l'APK dans le dossier **Téléchargements** du système.
     *
     * ## Pourquoi, alors qu'on sait lancer l'installateur
     *
     * Demande de Jay, 2026-08-16 : *« télécharger l'APK, cela pourrait se faire
     * comme dans Chrome : on télécharge, on voit dans les téléchargements, on
     * clique et cela lance l'installateur »*.
     *
     * Il a raison, et ça vaut mieux que ce que j'avais fait. Le fichier posé
     * dans le stockage privé de l'app **n'existe que pour l'app** : si
     * l'intention d'installation échoue — autorisation refusée, constructeur
     * qui filtre, écran qui se ferme — le téléchargement est perdu et il faut
     * tout recommencer. Dans les Téléchargements, il reste **atteignable
     * autrement**, exactement comme un fichier venu du navigateur.
     *
     * C'est un filet, pas un doublon : les deux chemins mènent au même
     * installateur système, mais l'un ne dépend pas de l'autre.
     *
     * ⚠️ `MediaStore` et non un chemin en dur : depuis Android 10, écrire
     * directement dans `/sdcard/Download` est refusé (stockage cloisonné).
     */
    private fun publishToDownloads(file: File, result: MethodChannel.Result) {
        try {
            val resolver = activity.contentResolver
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(
                    android.provider.MediaStore.Downloads.MIME_TYPE,
                    "application/vnd.android.package-archive",
                )
            }
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
            } else {
                @Suppress("DEPRECATION")
                Uri.fromFile(
                    android.os.Environment.getExternalStoragePublicDirectory(
                        android.os.Environment.DIRECTORY_DOWNLOADS,
                    ),
                )
            }
            val uri = resolver.insert(collection, values)
                ?: return result.error("NO_URI", "Téléchargements inaccessibles", null)
            resolver.openOutputStream(uri).use { out ->
                if (out == null) {
                    result.error("NO_STREAM", "Écriture impossible", null)
                    return
                }
                file.inputStream().use { it.copyTo(out) }
            }
            result.success(file.name)
        } catch (e: Exception) {
            // Un échec ici ne doit PAS empêcher l'installation directe : ce
            // chemin est un filet, pas le chemin principal.
            result.error("PUBLISH_FAILED", e.message ?: e.toString(), null)
        }
    }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
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

        when (call.method) {
            "publish" -> return publishToDownloads(file, result)
            "install" -> Unit
            else -> return result.notImplemented()
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
