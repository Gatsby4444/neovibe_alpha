package com.neovibe.neovibe.map

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import com.mapbox.android.gestures.ShoveGestureDetector
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.plugin.gestures.OnShoveListener
import com.mapbox.maps.plugin.gestures.gestures
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap

/**
 * **Les gestes de la carte, réglés dans le moteur de Mapbox** (2026-09-26).
 *
 * ## Pourquoi ici, et pas dans Flutter
 *
 * Jay : *« l'app ne détecte pas assez précisément le mouvement des doigts,
 * là où Google est ultra précis »*. La v0.9.281-282 reconnaissait les gestes
 * à deux doigts dans Flutter, puis envoyait la caméra par messages, un à la
 * fois : un temps de retard, des positions sautées, et le zoom ne gardait
 * pas sous les doigts ce qui s'y trouvait. Le moteur de Mapbox, lui, lit
 * les doigts directement, sur le fil d'Android — et il a déjà la
 * hiérarchie de Google (lu dans son code : un zoom parti en premier coupe
 * la rotation quand `simultaneousRotateAndPinchToZoomEnabled` est faux ;
 * une rotation partie en premier laisse le zoom s'ajouter ; une
 * inclinaison coupe le déplacement). Seuls ses SEUILS étaient mal réglés
 * pour la règle de Jay. Les uns sont des ressources
 * (`res/values/mapbox_gestures.xml`) ; les trois ci-dessous sont écrits en
 * dur dans son `initializeGesturesManager`, et se règlent ici :
 *
 * - [rotateDeg] : l'angle avant qu'une rotation parte (3° chez Mapbox —
 *   deux doigts qui montent ensemble tournent toujours un peu, et cette
 *   rotation parasite interdisait l'inclinaison) ;
 * - [shoveMaxDeg] : jusqu'à quel angle les doigts peuvent être de travers
 *   pour incliner (45° chez Mapbox) ;
 * - [pitchBoost] : la vitesse de l'inclinaison (Mapbox : 0,1° par pixel,
 *   ~3 cm de course pour 60° sur ce téléphone — « trop », dit Jay).
 *
 * ## Comment la carte est trouvée — et la limite, dite
 *
 * Le paquet Flutter ne donne pas accès à la vue native de la carte. On la
 * cherche dans les vues de l'écran : en mode « couche de texture » ou
 * « vue native », Flutter l'y accroche. En mode « écran virtuel », elle vit
 * sur un écran à part et reste introuvable : les seuils de Mapbox s'y
 * appliquent (les ressources, elles, valent partout). La réponse dit
 * combien de cartes ont été trouvées et réglées — un zéro se voit au
 * journal, il ne se devine pas.
 */
class MapGestureTuner(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/map_gestures")
    private val main = Handler(Looper.getMainLooper())

    /** Les cartes déjà réglées : une carte ne reçoit qu'UN écouteur. */
    private val reglees = WeakHashMap<MapView, Boolean>()

    private var rotateDeg = 10f
    private var shoveMaxDeg = 60f
    private var pitchBoost = 2.0

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "tune" -> {
                call.argument<Double>("rotateDeg")?.let { rotateDeg = it.toFloat() }
                call.argument<Double>("shoveMaxDeg")?.let { shoveMaxDeg = it.toFloat() }
                call.argument<Double>("pitchBoost")?.let { pitchBoost = it }
                main.post { result.success(reglerTout()) }
            }
            else -> result.notImplemented()
        }
    }

    private fun reglerTout(): Map<String, Int> {
        val cartes = mutableListOf<MapView>()
        chercher(activity.window?.decorView, cartes)
        var nouvelles = 0
        for (carte in cartes) {
            if (reglees.containsKey(carte)) continue
            if (runCatching { regler(carte) }.isSuccess) {
                reglees[carte] = true
                nouvelles++
            }
        }
        return mapOf("trouvees" to cartes.size, "reglees" to nouvelles)
    }

    private fun chercher(vue: View?, cartes: MutableList<MapView>) {
        when (vue) {
            is MapView -> cartes.add(vue)
            is ViewGroup -> for (i in 0 until vue.childCount) chercher(vue.getChildAt(i), cartes)
        }
    }

    private fun regler(carte: MapView) {
        val gestes = carte.gestures
        val manager = gestes.getGesturesManager()
        manager.rotateGestureDetector.angleThreshold = rotateDeg
        manager.shoveGestureDetector.maxShoveAngle = shoveMaxDeg
        // L'inclinaison plus vive : Mapbox a déjà appliqué sa part
        // (0,1° par pixel) quand cet écouteur est appelé ; on ajoute le
        // reste, dans la même borne que lui (0 à 85°).
        gestes.addOnShoveListener(object : OnShoveListener {
            override fun onShoveBegin(detector: ShoveGestureDetector) {}
            override fun onShove(detector: ShoveGestureDetector) {
                val carteMapbox = carte.mapboxMap
                val pitch = (carteMapbox.cameraState.pitch -
                    (pitchBoost - 1.0) * 0.1 * detector.deltaPixelSinceLast)
                    .coerceIn(0.0, 85.0)
                carteMapbox.setCamera(CameraOptions.Builder().pitch(pitch).build())
            }
            override fun onShoveEnd(detector: ShoveGestureDetector) {}
        })
    }
}
