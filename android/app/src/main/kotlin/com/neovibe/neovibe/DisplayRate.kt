package com.neovibe.neovibe

import android.app.Activity
import android.os.Build
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * **La cadence de l'écran : demander la plus fluide** (2026-09-26).
 *
 * ## Pourquoi
 *
 * Jay trouve la carte « saccadée » à côté de Google Maps. Le journal des
 * gestes l'a MESURÉ : la carte dessine chaque image en 4 à 7 ms — de quoi en
 * faire plus de 150 par seconde — mais n'en affiche que 55 à 76. Le dessin
 * n'est donc pas le goulot. Son téléphone (Redmi Note 10 Pro, M2101K6G) a un
 * écran 120 Hz ; sur les Xiaomi, une app qui ne demande rien est souvent
 * tenue à 60 images par seconde, là où Google Maps demande 120.
 *
 * ## Ce qu'on fait
 *
 * On demande, pour la fenêtre de l'app, le mode d'écran le plus rapide à
 * la MÊME définition (`preferredDisplayModeId`). Android et le réglage du
 * téléphone restent maîtres : si l'utilisateur a choisi 60 Hz dans ses
 * réglages, ou en économie d'énergie, le système peut refuser. La réponse
 * de [etat] dit ce qui a été demandé et ce que l'écran fait VRAIMENT — un
 * instrument, dans le diagnostic.
 *
 * Le coût : un écran à 120 Hz consomme davantage. C'est ce que font les
 * autres apps fluides (Google Maps, Instagram) ; à revoir si Jay le juge
 * trop cher.
 *
 * iOS : `CADisplayLink.preferredFrameRateRange` + clé
 * `CADisableMinimumFrameDurationOnPhone` dans Info.plist (ProMotion).
 */
class DisplayRate(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/display")

    /** Ce qui a été relevé et demandé au lancement, pour le diagnostic. */
    private var avantHz = 0f
    private var demande = "rien"

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    /** Demande le mode le plus rapide à la même définition. */
    fun demanderLePlusFluide() {
        val ecran = ecran() ?: return
        avantHz = ecran.refreshRate
        val courant = ecran.mode
        val meilleur = ecran.supportedModes
            .filter {
                it.physicalWidth == courant.physicalWidth &&
                    it.physicalHeight == courant.physicalHeight
            }
            .maxByOrNull { it.refreshRate } ?: return
        val attributs = activity.window.attributes
        attributs.preferredDisplayModeId = meilleur.modeId
        activity.window.attributes = attributs
        demande = "mode ${meilleur.modeId} (${meilleur.refreshRate.toInt()} Hz)"
    }

    private fun ecran(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "etat") return result.notImplemented()
        val ecran = ecran()
        if (ecran == null) {
            result.success("écran introuvable")
            return
        }
        val modes = ecran.supportedModes.joinToString(", ") {
            "${it.physicalWidth}×${it.physicalHeight} ${it.refreshRate.toInt()} Hz"
        }
        result.success(
            "modes possibles : $modes\n" +
                "au lancement    : ${avantHz.toInt()} Hz\n" +
                "demandé         : $demande\n" +
                "MAINTENANT      : ${ecran.refreshRate.toInt()} Hz",
        )
    }
}
