package com.neovibe.neovibe

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * **Ce qu'Android a REELLEMENT accorde comme position.** Rien d'autre.
 *
 * ## Pourquoi ce fichier existe : la panne du 2026-08-26
 *
 * Le Dart concluait « position approximative » en lisant la precision de la
 * DERNIERE POSITION CONNUE : au-dela de 500 m, il declarait la permission
 * insuffisante. C'est un raisonnement sur un cache, pas sur une permission.
 *
 * Un dernier point issu du reseau (WiFi, cellules) depasse couramment 500 m
 * **meme quand la position precise est accordee**. L'app affichait donc
 * « choisis Precise dans les reglages » a un utilisateur qui l'avait deja fait,
 * et le blocage etait sans issue : Jay a cherche une autorisation qui n'existait
 * pas. Cote serveur, sa balise n'est jamais partie — une seule ligne dans
 * `ping_beacons` la ou il en fallait deux.
 *
 * `geolocator` ne distingue pas `ACCESS_FINE_LOCATION` de
 * `ACCESS_COARSE_LOCATION` : il rend `whileInUse` dans les deux cas. Or c'est
 * exactement la question a poser. Android y repond en une ligne, et c'est un
 * **fait**, pas une deduction.
 *
 * ## Ce que ce pont ne fait pas
 *
 * Il ne demande rien, n'ouvre aucun reglage, ne decide de rien. Constater et
 * demander sont deux gestes differents ; le second appartient a la vue, qui
 * seule sait quand deranger l'utilisateur.
 */
class LocationGrant(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/location")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "grant") {
            result.notImplemented()
            return
        }
        result.success(
            mapOf(
                "fine" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
                "coarse" to granted(Manifest.permission.ACCESS_COARSE_LOCATION),
            ),
        )
    }

    /** `Context.checkSelfPermission` : API 23+, et notre plancher est 29. Pas
     *  besoin d'androidx pour lire une permission. */
    private fun granted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun dispose() = channel.setMethodCallHandler(null)
}
