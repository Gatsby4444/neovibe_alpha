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
import com.mapbox.common.Cancelable
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.RenderModeType
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
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max

/**
 * **Les gestes de la carte, réglés dans le moteur de Mapbox** (2026-09-26).
 *
 * ## Pourquoi ici, et pas dans Flutter
 *
 * Jay : *« l'app ne détecte pas assez précisément le mouvement des doigts,
 * là où Google est ultra précis »*. La v0.9.281-282 reconnaissait les gestes
 * à deux doigts dans Flutter, puis envoyait la caméra par messages : retard,
 * positions sautées. Ici, on lit les doigts AVANT la carte, sur le fil
 * d'Android (`setOnTouchListener` passe avant son `onTouchEvent`), et c'est
 * toujours Mapbox qui déplace la carte, avec sa précision.
 *
 * ## Ce que ce fichier fait
 *
 * 1. **L'arbitrage à deux doigts, comme Google** (Jay, 2026-09-26 : *« il
 *    m'arrive de vouloir incliner et au final ça tourne la carte, ou de
 *    vouloir tourner et ça zoome »*). Chez Mapbox, le PREMIER détecteur qui
 *    atteint son seuil gagne. Tant que deux doigts n'ont pas bougé de
 *    [decisionDp], zoom, rotation et inclinaison sont retenus ; puis on
 *    compare trois mouvements — variation d'écart, arc de rotation,
 *    glissement commun — et seul le détecteur du plus grand est libéré (la
 *    rotation avec le zoom, comme Google). Le glissement reste libre : la
 *    carte suit les doigts pendant ce temps, et un glissement vertical
 *    devient une inclinaison après ses 20dp (`mapbox_gestures.xml`).
 * 2. **Le verrou** (journal de Jay : 11 inclinaisons sur 12 finissaient par
 *    un déplacement) : dès qu'un zoom à deux doigts, une rotation ou une
 *    inclinaison part, le déplacement est coupé jusqu'au dernier doigt levé.
 * 3. **Les seuils écrits en dur** : [shoveMaxDeg] (doigts de travers pour
 *    incliner), [pitchBoost] (vitesse de l'inclinaison), et l'angle de
 *    départ d'une rotation une fois l'arbitrage rendu ([rotateDeg]).
 * 4. **L'élan des listes d'Android** : Mapbox n'en donne qu'au-delà de
 *    1 000 dp/s (`handleFlingEvent`) ; ici, dès la vitesse minimale d'un
 *    lancer, avec [OverScroller]. Pendant l'élan, la carte est prévenue qu'un
 *    geste est en cours (`setGestureInProgress`) : comme pour ses propres
 *    gestes, elle allège son travail (textes, finitions) pour la fluidité.
 * 5. **Le journal des gestes** — un instrument : ce que Mapbox a reconnu,
 *    dans l'ordre, l'arbitrage, et les IMAGES dessinées pendant le geste
 *    (nombre par seconde, durée de dessin moyenne et maximale, images
 *    incomplètes — carte encore en chargement). Jay trouve la carte un peu
 *    saccadée : ce compte dira si le dessin est trop lent, ou si la cause
 *    est ailleurs.
 *
 * ## Comment la carte est trouvée — et la limite, dite
 *
 * Le paquet Flutter ne donne pas accès à la vue native de la carte. On la
 * cherche dans les vues de l'écran : en mode « couche de texture » ou « vue
 * native », Flutter l'y accroche. En mode « écran virtuel », elle reste
 * introuvable : rien de ce fichier ne s'y applique.
 */
class MapGestureTuner(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/map_gestures")
    private val main = Handler(Looper.getMainLooper())

    /** Les cartes déjà réglées, et ce qui les écoute (gardé en vie ici). */
    private val reglees = WeakHashMap<MapView, Cancelable>()

    private var rotateDeg = 5f
    private var shoveMaxDeg = 70f
    private var pitchBoost = 2.0

    /** Mouvement avant de décider quel geste font deux doigts. */
    private val decisionDp = 10f

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
            runCatching { regler(carte) }.onSuccess {
                reglees[carte] = it
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
    private fun regler(carte: MapView): Cancelable {
        val gestes = carte.gestures
        val manager = gestes.getGesturesManager()
        val deplacement = manager.moveGestureDetector
        val zoom = manager.standardScaleGestureDetector
        val rotation = manager.rotateGestureDetector
        val inclinaison = manager.shoveGestureDetector
        rotation.angleThreshold = rotateDeg
        inclinaison.maxShoveAngle = shoveMaxDeg
        val densite = carte.resources.displayMetrics.density

        val session = Session()
        val elan = Elan(carte) { ecrire(session.finir()) }

        fun verrouiller() {
            session.verrou = true
            deplacement.isEnabled = false
        }

        /** Seuls les détecteurs du geste choisi sont libérés. */
        fun liberer(zoomOk: Boolean, rotationOk: Boolean, inclinaisonOk: Boolean) {
            zoom.isEnabled = zoomOk
            rotation.isEnabled = rotationOk
            inclinaison.isEnabled = inclinaisonOk
        }

        carte.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    elan.arreter()
                    session.commencer(e)
                    // Un geste neuf : tout est rendu.
                    deplacement.isEnabled = true
                    liberer(zoomOk = true, rotationOk = true, inclinaisonOk = true)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    session.doigts(e)
                    // Deux doigts : zoom, rotation et inclinaison retenus le
                    // temps de voir ce que font les doigts (le zoom à UN
                    // doigt — double appui maintenu — n'est pas concerné).
                    if (e.pointerCount == 2 && session.arbitre == null) {
                        session.poser(e)
                        liberer(zoomOk = false, rotationOk = false, inclinaisonOk = false)
                    }
                }
                MotionEvent.ACTION_MOVE -> {
                    val choix = session.arbitrer(e, decisionDp * densite)
                    when (choix) {
                        "zoom" -> liberer(zoomOk = true, rotationOk = false, inclinaisonOk = false)
                        "rotation" -> liberer(zoomOk = true, rotationOk = true, inclinaisonOk = false)
                        "glissement" -> liberer(zoomOk = false, rotationOk = false, inclinaisonOk = true)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    // ⚠️ Le doigt levé compte dans la vitesse : un doigt
                    // immobilisé avant d'être levé ne lance rien.
                    session.vitesse.addMovement(e)
                    // Écrit APRÈS que la carte a traité ce doigt levé — et
                    // après l'élan s'il y en a un (il écrit lui-même).
                    main.post { if (!elan.actif) ecrire(session.finir()) }
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
                if (detector.pointersCount >= 2) verrouiller()
                session.debut("zoom", detector.pointersCount, detector.currentEvent)
            }
            override fun onScale(detector: StandardScaleGestureDetector) {}
            override fun onScaleEnd(detector: StandardScaleGestureDetector) {
                if (session.verrou) deplacement.isEnabled = false
            }
        })
        gestes.addOnRotateListener(object : OnRotateListener {
            override fun onRotateBegin(detector: RotateGestureDetector) {
                session.autreGeste = true
                verrouiller()
                session.debut("rotation", detector.pointersCount, detector.currentEvent)
            }
            override fun onRotate(detector: RotateGestureDetector) {}
            override fun onRotateEnd(detector: RotateGestureDetector) {
                if (session.verrou) deplacement.isEnabled = false
            }
        })
        gestes.addOnShoveListener(object : OnShoveListener {
            override fun onShoveBegin(detector: ShoveGestureDetector) {
                session.autreGeste = true
                verrouiller()
                session.debut("inclinaison", detector.pointersCount, detector.currentEvent)
            }
            // L'inclinaison plus vive : Mapbox a déjà appliqué sa part
            // (0,1° par pixel) ; on ajoute le reste, dans sa borne (0 à 85°).
            override fun onShove(detector: ShoveGestureDetector) {
                val carteMapbox = carte.mapboxMap
                val pitch = (carteMapbox.cameraState.pitch -
                    (pitchBoost - 1.0) * 0.1 * detector.deltaPixelSinceLast)
                    .coerceIn(0.0, 85.0)
                carteMapbox.setCamera(CameraOptions.Builder().pitch(pitch).build())
            }
            // ⚠️ Mapbox REND le déplacement à la fin d'une inclinaison
            // (`GestureState.restore`) avant d'appeler cet écouteur.
            override fun onShoveEnd(detector: ShoveGestureDetector) {
                if (session.verrou) deplacement.isEnabled = false
            }
        })

        // Chaque image dessinée pendant un geste ou un élan est comptée.
        return carte.mapboxMap.subscribeRenderFrameFinished { image ->
            if (session.enCours || elan.actif) {
                val t = image.timeInterval
                session.image(
                    t.begin.time,
                    t.end.time,
                    image.renderMode == RenderModeType.PARTIAL,
                )
            }
        }
    }

    private fun ecrire(ligne: String?) {
        ligne ?: return
        journal.addLast(ligne)
        while (journal.size > 40) journal.removeFirst()
    }

    /**
     * **Un geste, du premier doigt posé au dernier levé (élan compris)** : ce
     * qui y a été reconnu, dans l'ordre, et les images dessinées. Ne décide
     * de rien, sauf l'arbitrage — isolé dans [arbitrer].
     */
    private class Session {
        val vitesse: VelocityTracker = VelocityTracker.obtain()
        var multi = false
        var autreGeste = false
        var verrou = false
        var elan = 0
        var enCours = false

        /** Le geste choisi par l'arbitrage à deux doigts ; nul = pas encore. */
        var arbitre: String? = null
        private var idA = -1
        private var idB = -1
        private var ax = 0f
        private var ay = 0f
        private var bx = 0f
        private var by = 0f
        private var enAttente = false

        private var debutMs = 0L
        private var maxDoigts = 0
        private val etapes = mutableListOf<String>()

        private var images = 0
        private var partielles = 0
        private var dessinTotalMs = 0L
        private var dessinMaxMs = 0L
        private var premiereFinMs = 0L
        private var derniereFinMs = 0L
        private var ecartMaxMs = 0L

        fun commencer(e: MotionEvent) {
            multi = false
            autreGeste = false
            verrou = false
            elan = 0
            enCours = true
            arbitre = null
            enAttente = false
            debutMs = System.currentTimeMillis()
            maxDoigts = e.pointerCount
            etapes.clear()
            vitesse.clear()
            images = 0
            partielles = 0
            dessinTotalMs = 0
            dessinMaxMs = 0
            premiereFinMs = 0
            derniereFinMs = 0
            ecartMaxMs = 0
        }

        fun doigts(e: MotionEvent) {
            maxDoigts = maxOf(maxDoigts, e.pointerCount)
        }

        /** Le deuxième doigt est posé : les positions de départ. */
        fun poser(e: MotionEvent) {
            idA = e.getPointerId(0)
            idB = e.getPointerId(1)
            ax = e.getX(0); ay = e.getY(0)
            bx = e.getX(1); by = e.getY(1)
            enAttente = true
        }

        /**
         * **Quel geste font les deux doigts ?** Rien avant [seuilPx] de
         * mouvement ; puis le plus grand de : variation d'écart (zoom), arc
         * parcouru en tournant (rotation), glissement COMMUN — seulement si
         * les deux doigts vont dans le même sens. Rend le choix une seule
         * fois, nul sinon.
         */
        fun arbitrer(e: MotionEvent, seuilPx: Float): String? {
            if (!enAttente) return null
            val ia = e.findPointerIndex(idA)
            val ib = e.findPointerIndex(idB)
            if (ia < 0 || ib < 0) return null
            val dax = e.getX(ia) - ax
            val day = e.getY(ia) - ay
            val dbx = e.getX(ib) - bx
            val dby = e.getY(ib) - by
            val ecart0 = hypot(bx - ax, by - ay)
            val ecart = hypot(e.getX(ib) - e.getX(ia), e.getY(ib) - e.getY(ia))
            var angle = Math.toDegrees(
                (atan2(e.getY(ib) - e.getY(ia), e.getX(ib) - e.getX(ia)) -
                    atan2(by - ay, bx - ax)).toDouble(),
            )
            angle = ((angle + 540) % 360) - 180
            val zoomPx = abs(ecart - ecart0)
            val rotationPx = (abs(angle) * PI / 180 * ecart0 / 2).toFloat()
            val ensemble = dax * dbx + day * dby > 0
            val glissePx = if (ensemble) hypot((dax + dbx) / 2, (day + dby) / 2) else 0f
            val plus = max(zoomPx, max(rotationPx, glissePx))
            if (plus < seuilPx) return null
            enAttente = false
            val choix = when (plus) {
                glissePx -> "glissement"
                rotationPx -> "rotation"
                else -> "zoom"
            }
            arbitre = choix
            etapes.add(
                "arbitrage : $choix (écart ${zoomPx.toInt()} px, arc ${rotationPx.toInt()} px, " +
                    "glissé ${glissePx.toInt()} px)",
            )
            return choix
        }

        /** Un détecteur de Mapbox part : lequel, doigts, écart et angle. */
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

        /** Une image dessinée : début et fin du dessin, carte incomplète ? */
        fun image(debutDessinMs: Long, finDessinMs: Long, partielle: Boolean) {
            val dessin = finDessinMs - debutDessinMs
            images++
            if (partielle) partielles++
            dessinTotalMs += dessin
            dessinMaxMs = maxOf(dessinMaxMs, dessin)
            if (premiereFinMs == 0L) premiereFinMs = finDessinMs
            if (derniereFinMs != 0L) ecartMaxMs = maxOf(ecartMaxMs, finDessinMs - derniereFinMs)
            derniereFinMs = finDessinMs
        }

        fun finir(): String? {
            if (!enCours) return null
            enCours = false
            if (etapes.isEmpty()) return null
            val heure = SimpleDateFormat("HH:mm:ss", Locale.FRANCE).format(Date(debutMs))
            val fin = if (elan > 0) " → élan $elan px/s" else ""
            val duree = derniereFinMs - premiereFinMs
            val rendu = if (images >= 2 && duree > 0) {
                val parSeconde = (images - 1) * 1000 / duree
                " · IMAGES : $images, $parSeconde/s, dessin moyen ${dessinTotalMs / images} ms, " +
                    "max ${dessinMaxMs} ms, plus long trou ${ecartMaxMs} ms" +
                    (if (partielles > 0) ", $partielles en chargement" else "")
            } else ""
            return "$heure · $maxDoigts doigt${if (maxDoigts > 1) "s" else ""} : " +
                etapes.joinToString(" → ") + fin + rendu
        }
    }

    /**
     * **L'élan d'une liste, appliqué à la carte** : [OverScroller] calcule,
     * image par image, de combien la carte continue de glisser ; chaque pas
     * est traduit par Mapbox lui-même (`cameraForDrag`).
     */
    private class Elan(
        private val carte: MapView,
        private val quandFini: () -> Unit,
    ) : Choreographer.FrameCallback {
        private val scroller = OverScroller(carte.context)
        private var dernierX = 0
        private var dernierY = 0
        var actif = false
            private set

        fun lancer(vx: Float, vy: Float) {
            arreter()
            dernierX = 0
            dernierY = 0
            scroller.fling(
                0, 0, vx.toInt(), vy.toInt(),
                Int.MIN_VALUE, Int.MAX_VALUE, Int.MIN_VALUE, Int.MAX_VALUE,
            )
            actif = true
            // Comme pendant ses propres gestes : la carte allège son travail
            // (textes, finitions) tant que ça bouge.
            carte.mapboxMap.setGestureInProgress(true)
            Choreographer.getInstance().postFrameCallback(this)
        }

        fun arreter() {
            if (!actif) return
            scroller.forceFinished(true)
            Choreographer.getInstance().removeFrameCallback(this)
            fin()
        }

        private fun fin() {
            actif = false
            carte.mapboxMap.setGestureInProgress(false)
            quandFini()
        }

        override fun doFrame(frameTimeNanos: Long) {
            if (!actif) return
            if (!scroller.computeScrollOffset()) {
                fin()
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
                fin()
            } else {
                Choreographer.getInstance().postFrameCallback(this)
            }
        }
    }
}
