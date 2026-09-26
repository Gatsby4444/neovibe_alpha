package com.neovibe.neovibe.map

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.OverScroller
import com.mapbox.android.gestures.MoveGestureDetector
import com.mapbox.android.gestures.RotateGestureDetector
import com.mapbox.android.gestures.ShoveGestureDetector
import com.mapbox.android.gestures.StandardScaleGestureDetector
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.ScreenCoordinate
import com.mapbox.maps.plugin.gestures.OnMoveListener
import com.mapbox.maps.plugin.gestures.OnRotateListener
import com.mapbox.maps.plugin.gestures.OnScaleListener
import com.mapbox.maps.plugin.gestures.OnShoveListener
import com.mapbox.maps.plugin.gestures.gestures
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.WeakHashMap
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * **Les gestes de la carte, réglés dans le moteur de Mapbox** (2026-09-26).
 *
 * ## Pourquoi ici, et pas dans Flutter
 *
 * Jay : *« l'app ne détecte pas assez précisément le mouvement des doigts,
 * là où Google est ultra précis »*. La v0.9.281-282 reconnaissait les gestes
 * à deux doigts dans Flutter, puis envoyait la caméra par messages : retard,
 * positions sautées. Le moteur de Mapbox lit les doigts directement, sur le
 * fil d'Android — et il a déjà la hiérarchie de Google (lu dans son code :
 * un zoom parti en premier coupe la rotation quand
 * `simultaneousRotateAndPinchToZoomEnabled` est faux ; une rotation partie en
 * premier laisse le zoom s'ajouter ; une inclinaison coupe le déplacement).
 * Seuls ses SEUILS sont réglés : les uns en ressources
 * (`res/values/mapbox_gestures.xml`), les autres — écrits en dur dans son
 * `initializeGesturesManager` — ici.
 *
 * ## Ce que ce fichier fait
 *
 * 1. **Les seuils écrits en dur** : [rotateDeg] (angle avant qu'une rotation
 *    parte), [shoveMaxDeg] (jusqu'où les doigts peuvent être de travers pour
 *    incliner), [pitchBoost] (vitesse de l'inclinaison).
 * 2. **L'élan** (Jay, 2026-09-26 : *« comme un scroll dans un fil, plus le
 *    geste est fort plus on va loin »*). Mapbox n'en donne qu'au-delà de
 *    1 000 dp/s (`handleFlingEvent`, écrit en dur) : sous ce seuil — la
 *    plupart des gestes — la carte s'arrêtait net. On le remplace par celui
 *    des listes d'Android ([OverScroller]) : dès la vitesse minimale d'un
 *    lancer, la distance suit la force du geste, et un doigt posé l'arrête.
 *    Seulement après un déplacement à UN doigt, sans zoom, rotation ni
 *    inclinaison dans le même geste. L'élan de Mapbox est coupé côté Dart
 *    (`scrollDecelerationEnabled: false`) : deux élans se battraient.
 * 3. **Le journal des gestes** — un instrument : pour chaque geste, ce que
 *    Mapbox a reconnu, dans l'ordre, avec le nombre de doigts, leur écart et
 *    leur angle. Jay voit parfois la carte se déplacer au lieu de s'incliner ;
 *    le journal dira QUEL détecteur est parti, au lieu qu'on le devine.
 *
 * ## Comment la carte est trouvée — et la limite, dite
 *
 * Le paquet Flutter ne donne pas accès à la vue native de la carte. On la
 * cherche dans les vues de l'écran : en mode « couche de texture » ou « vue
 * native », Flutter l'y accroche. En mode « écran virtuel », elle reste
 * introuvable : ni seuils écrits en dur, ni élan, ni journal. La réponse dit
 * combien de cartes ont été trouvées et réglées.
 */
class MapGestureTuner(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/map_gestures")
    private val main = Handler(Looper.getMainLooper())

    /** Les cartes déjà réglées : une carte ne reçoit qu'UN jeu d'écouteurs. */
    private val reglees = WeakHashMap<MapView, Boolean>()

    private var rotateDeg = 10f
    private var shoveMaxDeg = 70f
    private var pitchBoost = 2.0

    /** Les derniers gestes, du plus ancien au plus récent. */
    private val journal = ArrayDeque<String>()

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
            "journal" -> main.post { result.success(journal.joinToString("\n")) }
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

    @SuppressLint("ClickableViewAccessibility")
    private fun regler(carte: MapView) {
        val gestes = carte.gestures
        val manager = gestes.getGesturesManager()
        manager.rotateGestureDetector.angleThreshold = rotateDeg
        manager.shoveGestureDetector.maxShoveAngle = shoveMaxDeg

        val session = Session()
        val elan = Elan(carte)

        // Un doigt posé : l'élan en cours s'arrête (comme une liste), et un
        // nouveau geste commence. Un doigt levé : le geste est écrit au
        // journal. `false` : la carte traite toujours le toucher elle-même.
        carte.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    elan.arreter()
                    session.commencer(e)
                }
                MotionEvent.ACTION_POINTER_DOWN -> session.doigts(e)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    // ⚠️ Le doigt levé compte dans la vitesse : un doigt
                    // immobilisé avant d'être levé ne lance rien — sans
                    // cette ligne, l'élan reprendrait la vitesse d'avant
                    // l'arrêt (c'est ce que font les listes d'Android).
                    session.vitesse.addMovement(e)
                    // Écrit APRÈS que la carte a traité ce doigt levé (et
                    // décidé de l'élan) : le journal dit aussi l'élan.
                    main.post { ecrire(session.finir()) }
                }
            }
            false
        }

        gestes.addOnMoveListener(object : OnMoveListener {
            override fun onMoveBegin(detector: MoveGestureDetector) {
                session.debut("déplacement", detector.pointersCount, detector.currentEvent)
                session.vitesse.clear()
            }
            override fun onMove(detector: MoveGestureDetector): Boolean {
                session.vitesse.addMovement(detector.currentEvent)
                if (detector.pointersCount > 1) session.multi = true
                return false
            }
            override fun onMoveEnd(detector: MoveGestureDetector) {
                if (session.multi || session.autreGeste) return
                session.vitesse.computeCurrentVelocity(1000)
                val vx = session.vitesse.xVelocity
                val vy = session.vitesse.yVelocity
                val mini = ViewConfiguration.get(carte.context).scaledMinimumFlingVelocity
                if (hypot(vx, vy) >= mini) {
                    elan.lancer(vx, vy)
                    session.elan = hypot(vx, vy).toInt()
                }
            }
        })
        gestes.addOnScaleListener(object : OnScaleListener {
            override fun onScaleBegin(detector: StandardScaleGestureDetector) {
                session.autreGeste = true
                session.debut("zoom", detector.pointersCount, detector.currentEvent)
            }
            override fun onScale(detector: StandardScaleGestureDetector) {}
            override fun onScaleEnd(detector: StandardScaleGestureDetector) {}
        })
        gestes.addOnRotateListener(object : OnRotateListener {
            override fun onRotateBegin(detector: RotateGestureDetector) {
                session.autreGeste = true
                session.debut("rotation", detector.pointersCount, detector.currentEvent)
            }
            override fun onRotate(detector: RotateGestureDetector) {}
            override fun onRotateEnd(detector: RotateGestureDetector) {}
        })
        gestes.addOnShoveListener(object : OnShoveListener {
            override fun onShoveBegin(detector: ShoveGestureDetector) {
                session.autreGeste = true
                session.debut("inclinaison", detector.pointersCount, detector.currentEvent)
            }
            // L'inclinaison plus vive : Mapbox a déjà appliqué sa part
            // (0,1° par pixel) quand cet écouteur est appelé ; on ajoute le
            // reste, dans la même borne que lui (0 à 85°).
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

    private fun ecrire(ligne: String?) {
        ligne ?: return
        journal.addLast(ligne)
        while (journal.size > 40) journal.removeFirst()
    }

    /**
     * **Un geste, du premier doigt posé au dernier levé** : ce que Mapbox y a
     * reconnu, dans l'ordre. Rien n'y est décidé ; il ne fait que noter.
     */
    private class Session {
        val vitesse: VelocityTracker = VelocityTracker.obtain()
        var multi = false
        var autreGeste = false
        var elan = 0
        private var debutMs = 0L
        private var maxDoigts = 0
        private val etapes = mutableListOf<String>()

        fun commencer(e: MotionEvent) {
            multi = false
            autreGeste = false
            elan = 0
            debutMs = System.currentTimeMillis()
            maxDoigts = e.pointerCount
            etapes.clear()
            vitesse.clear()
        }

        fun doigts(e: MotionEvent) {
            maxDoigts = maxOf(maxDoigts, e.pointerCount)
        }

        /** Un détecteur part : lequel, à combien de doigts, écart et angle. */
        fun debut(quoi: String, doigts: Int, e: MotionEvent?) {
            val apres = System.currentTimeMillis() - debutMs
            val forme = if (e != null && e.pointerCount >= 2) {
                val dx = e.getX(1) - e.getX(0)
                val dy = e.getY(1) - e.getY(0)
                val angle = Math.toDegrees(abs(atan2(dy, dx)).toDouble()).let {
                    if (it > 90) 180 - it else it
                }
                " (écart ${hypot(dx, dy).toInt()} px, doigts à ${angle.toInt()}° de l'horizontale)"
            } else ""
            etapes.add("$quoi à $doigts doigt${if (doigts > 1) "s" else ""} après $apres ms$forme")
        }

        fun finir(): String? {
            if (etapes.isEmpty()) return null
            val heure = SimpleDateFormat("HH:mm:ss", Locale.FRANCE).format(Date(debutMs))
            val fin = if (elan > 0) " → élan $elan px/s" else ""
            return "$heure · $maxDoigts doigt${if (maxDoigts > 1) "s" else ""} : " +
                etapes.joinToString(" → ") + fin
        }
    }

    /**
     * **L'élan d'une liste, appliqué à la carte** : le moteur de défilement
     * d'Android ([OverScroller]) calcule, image par image, de combien la
     * carte continue de glisser ; chaque pas est traduit en déplacement de
     * caméra par Mapbox lui-même (`cameraForDrag`, celui de son propre élan).
     */
    private class Elan(private val carte: MapView) : Choreographer.FrameCallback {
        private val scroller = OverScroller(carte.context)
        private var dernierX = 0
        private var dernierY = 0
        private var actif = false

        fun lancer(vx: Float, vy: Float) {
            arreter()
            dernierX = 0
            dernierY = 0
            scroller.fling(
                0, 0, vx.toInt(), vy.toInt(),
                Int.MIN_VALUE, Int.MAX_VALUE, Int.MIN_VALUE, Int.MAX_VALUE,
            )
            actif = true
            Choreographer.getInstance().postFrameCallback(this)
        }

        fun arreter() {
            if (!actif) return
            actif = false
            scroller.forceFinished(true)
            Choreographer.getInstance().removeFrameCallback(this)
        }

        override fun doFrame(frameTimeNanos: Long) {
            if (!actif || !scroller.computeScrollOffset()) {
                actif = false
                return
            }
            val dx = scroller.currX - dernierX
            val dy = scroller.currY - dernierY
            dernierX = scroller.currX
            dernierY = scroller.currY
            if (dx != 0 || dy != 0) {
                val m = carte.mapboxMap
                val depuis = ScreenCoordinate(carte.width / 2.0, carte.height / 2.0)
                val vers = ScreenCoordinate(depuis.x + dx, depuis.y + dy)
                runCatching { m.setCamera(m.cameraForDrag(depuis, vers)) }
            }
            if (scroller.isFinished) {
                actif = false
            } else {
                Choreographer.getInstance().postFrameCallback(this)
            }
        }
    }
}
