package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

/**
 * Moteur double flux Oneshot en **Camera2 BRUT** — contourne la déclaration
 * `getConcurrentCameraIds()` d'Android (que CameraX respecte, et qui dit
 * « non » sur le Redmi Note 10 Pro alors que la sonde `DualCameraProbe`
 * prouve que le matériel accepte deux flux d'aperçu).
 *
 * ## Règles apprises à la dure (v0.8.0 → v0.8.3)
 *
 * 1. **Tout ce qui touche à Flutter (TextureRegistry, SurfaceProducer,
 *    MethodChannel) DOIT s'exécuter sur le thread principal.** La v0.8.2
 *    ouvrait la caméra frontale depuis le thread caméra (`postDelayed`) et
 *    créait donc la texture + envoyait `previewInfo` hors du thread UI :
 *    `MethodChannel.invokeMethod` est annoté `@UiThread` → exception → CRASH.
 *    C'était la vraie cause du plantage remonté par Jay, pas le matériel.
 * 2. **Une réponse de canal, une seule fois** (`Reply`) : répondre deux fois à
 *    un `MethodChannel.Result` lève « Reply already submitted » et tue l'app.
 * 3. **Ouverture séquentielle** (arrière, puis frontale) : ouvrir les deux en
 *    même temps fait évincer la première.
 * 4. **Toujours libérer** : une caméra laissée ouverte verrouille le matériel
 *    (« Available cameras: 0 » jusqu'au redémarrage).
 *
 * ## Échelle de repli (le journal dit quel barreau a tenu)
 *
 * - **Plan A** : aperçu (texture Flutter) + ImageReader JPEG → 2 flux/caméra.
 * - **Plan B** : aperçu seul → 1 flux/caméra (la forme exacte que la sonde a
 *   validée) ; la photo se prend en reconfigurant brièvement la session.
 *
 * On mesure aussi les IMAGES REÇUES par caméra (compteurs de capture) : c'est
 * ce qui permet de distinguer, dans le journal, « le matériel évince » (les
 * compteurs se figent) de « le matériel donne des images mais l'aperçu est
 * noir » (les compteurs montent → problème de RENDU, pas de caméra).
 */
@SuppressLint("MissingPermission") // permission caméra déjà accordée
class Camera2Dual(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    private val previewInfoSink: (key: String, w: Int, h: Int, rot: Int) -> Unit,
) {
    private val manager =
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    private val cams = mutableMapOf<String, Cam>()
    var backTextureId: Long = -1
        private set
    var frontTextureId: Long = -1
        private set
    var active = false
        private set

    /** Dernier diagnostic lisible (HUD développeur). */
    var lastReport: String? = null
        private set

    private val previewSize = android.util.Size(1280, 720)

    /** État d'une caméra du duo. */
    private inner class Cam(val key: String, val id: String, val back: Boolean) {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var producer: TextureRegistry.SurfaceProducer? = null

        /** Surface de la texture Flutter, récupérée sur le THREAD PRINCIPAL. */
        var previewSurface: Surface? = null
        var reader: ImageReader? = null
        var sensorOrientation = 0

        /** Images effectivement reçues du capteur (preuve de vie du flux). */
        val frames = AtomicInteger(0)
        var evicted = false

        /** true = Plan A (un ImageReader est dans la session). */
        val hasReader: Boolean get() = reader != null
    }

    /** Garantit une réponse unique au canal (sinon : crash Flutter). */
    private inner class Reply(private val result: MethodChannel.Result) {
        private var done = false

        fun success(value: Any?) = onUi {
            if (done) return@onUi
            done = true
            result.success(value)
        }

        fun error(code: String, message: String) = onUi {
            if (done) return@onUi
            done = true
            CamLog.e("dual", "ÉCHEC $code : $message")
            lastReport = message
            result.error(code, message, null)
        }
    }

    private fun onUi(block: () -> Unit) = activity.runOnUiThread(block)

    // ------------------------------------------------------------------
    // Ouverture
    // ------------------------------------------------------------------

    fun open(result: MethodChannel.Result) {
        val reply = Reply(result)
        CamLog.i("dual", "=== OUVERTURE DOUBLE FLUX (Camera2 brut) ===")
        try {
            closeInternal() // repart toujours d'un état propre
            thread = HandlerThread("nv-cam2-dual").also { it.start() }
            handler = Handler(thread!!.looper)

            val backId = firstCamera(CameraCharacteristics.LENS_FACING_BACK)
            val frontId = firstCamera(CameraCharacteristics.LENS_FACING_FRONT)
            CamLog.i("dual", "caméras : arrière=$backId avant=$frontId (liste=${manager.cameraIdList.joinToString()})")
            if (backId == null || frontId == null) {
                closeInternal()
                reply.error("DUAL_UNSUPPORTED", "Caméra avant ou arrière introuvable")
                return
            }

            // 1) Arrière d'abord, seule, comme la sonde qui réussit.
            openCam("dualBack", backId, back = true, plan = 'A') { backOk ->
                if (!backOk) {
                    closeInternal()
                    reply.error("DUAL_UNSUPPORTED", "La caméra arrière n'a pas démarré (voir le journal)")
                    return@openCam
                }
                // 2) On la laisse produire des images avant de toucher à la frontale.
                handler?.postDelayed({
                    val backAlone = cams["dualBack"]?.frames?.get() ?: 0
                    CamLog.i("dual", "arrière seule : $backAlone images en 700 ms")
                    // createSurfaceProducer / invokeMethod = THREAD PRINCIPAL.
                    onUi {
                        openCam("dualFront", frontId, back = false, plan = 'A') { frontOk ->
                            if (!frontOk) {
                                closeInternal()
                                reply.error(
                                    "DUAL_UNSUPPORTED",
                                    "La caméra frontale n'a pas démarré (évincée ?) — voir le journal",
                                )
                                return@openCam
                            }
                            verifyBoth(backAlone, reply)
                        }
                    }
                }, 700)
            }
        } catch (e: Exception) {
            CamLog.e("dual", "exception à l'ouverture", e)
            closeInternal()
            reply.error("DUAL_UNSUPPORTED", "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * Les deux caméras sont ouvertes : elles doivent CONTINUER à produire des
     * images toutes les deux. Si l'arrière se fige, le service caméra l'a
     * évincée → double flux impossible sur cet appareil.
     */
    private fun verifyBoth(backAlone: Int, reply: Reply) {
        val back = cams["dualBack"]
        val front = cams["dualFront"]
        val backBefore = back?.frames?.get() ?: 0
        handler?.postDelayed({
            val backAfter = (back?.frames?.get() ?: 0) - backBefore
            val frontFrames = front?.frames?.get() ?: 0
            val evicted = back?.evicted == true || front?.evicted == true
            val report =
                "arrière seule=$backAlone | arrière depuis l'ouverture de la frontale=$backAfter | " +
                    "frontale=$frontFrames | éviction=$evicted | " +
                    "plan=${if (back?.hasReader == true) "A" else "B"}/" +
                    "${if (front?.hasReader == true) "A" else "B"}"
            CamLog.i("dual", "VÉRIFICATION 900 ms → $report")
            lastReport = report

            if (evicted || backAfter < 2 || frontFrames < 2) {
                CamLog.e(
                    "dual",
                    "les deux flux ne tiennent pas ensemble → retour vue simple",
                )
                closeInternal()
                reply.error("DUAL_UNSUPPORTED", "Flux non tenus ensemble ($report)")
                return@postDelayed
            }

            active = true
            CamLog.i(
                "dual",
                "SUCCÈS : deux flux vivants — textures back=$backTextureId front=$frontTextureId. " +
                    "Si l'aperçu est NOIR malgré ces images, le problème est le RENDU (texture Flutter), " +
                    "pas la caméra.",
            )
            reply.success(
                mapOf(
                    "backTextureId" to backTextureId,
                    "frontTextureId" to frontTextureId,
                    "report" to report,
                ),
            )
        }, 900)
    }

    /**
     * Ouvre une caméra et configure sa session. **À appeler sur le thread
     * principal** (crée une texture Flutter et notifie le Dart).
     */
    private fun openCam(
        key: String,
        id: String,
        back: Boolean,
        plan: Char,
        onReady: (Boolean) -> Unit,
    ) {
        val cam = Cam(key, id, back)
        cams[key] = cam
        cam.sensorOrientation = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

        val producer = textureRegistry.createSurfaceProducer()
        producer.setSize(previewSize.width, previewSize.height)
        cam.producer = producer
        // setSize AVANT getSurface, et sur le thread principal : la Surface est
        // ensuite utilisable telle quelle depuis le thread caméra.
        cam.previewSurface = producer.surface
        if (back) backTextureId = producer.id() else frontTextureId = producer.id()
        CamLog.i(
            "dual",
            "$key : ouverture caméra $id (capteur ${cam.sensorOrientation}°, " +
                "texture ${producer.id()}, aperçu ${previewSize.width}×${previewSize.height})",
        )

        // Le Dart doit connaître taille + rotation AVANT les premières images.
        previewInfoSink(key, previewSize.width, previewSize.height, cam.sensorOrientation)

        var settled = false
        fun ready(ok: Boolean) {
            if (settled) return
            settled = true
            onUi { onReady(ok) } // la suite recrée des textures → thread UI
        }

        manager.openCamera(
            id,
            object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    CamLog.i("dual", "$key : caméra ouverte")
                    cam.device = device
                    configure(cam, plan, ::ready)
                }

                override fun onDisconnected(device: CameraDevice) {
                    // Éviction : le service caméra a coupé ce flux.
                    CamLog.e("dual", "$key : ÉVINCÉE (onDisconnected) — le matériel a coupé ce flux")
                    cam.evicted = true
                    runCatching { device.close() }
                    ready(false)
                }

                override fun onError(device: CameraDevice, error: Int) {
                    CamLog.e("dual", "$key : erreur d'ouverture $error (${errorName(error)})")
                    cam.evicted = true
                    runCatching { device.close() }
                    ready(false)
                }
            },
            handler,
        )
    }

    /**
     * Configure la session. Plan A = aperçu + ImageReader JPEG (2 flux) ;
     * si le matériel refuse cette combinaison, Plan B = aperçu seul (1 flux,
     * la forme validée par la sonde), la photo passera par une
     * reconfiguration ponctuelle.
     */
    @Suppress("DEPRECATION")
    private fun configure(cam: Cam, plan: Char, ready: (Boolean) -> Unit) {
        val device = cam.device ?: return ready(false)
        val previewSurface = cam.previewSurface ?: return ready(false)

        val targets = mutableListOf(previewSurface)
        if (plan == 'A') {
            val reader = ImageReader.newInstance(
                previewSize.width, previewSize.height, ImageFormat.JPEG, 2,
            )
            cam.reader = reader
            targets += reader.surface
        }
        CamLog.i("dual", "${cam.key} : session plan $plan (${targets.size} flux)")

        device.createCaptureSession(
            targets,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    cam.session = session
                    val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                        .apply { addTarget(previewSurface) }
                    runCatching {
                        session.setRepeatingRequest(request.build(), frameCounter(cam), handler)
                    }.onFailure {
                        CamLog.e("dual", "${cam.key} : flux répétitif refusé", it)
                        return ready(false)
                    }
                    CamLog.i("dual", "${cam.key} : session configurée (plan $plan), aperçu démarré")
                    ready(true)
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    CamLog.e("dual", "${cam.key} : session plan $plan REFUSÉE par le matériel")
                    runCatching { session.close() }
                    if (plan == 'A') {
                        // Repli : la combinaison aperçu+photo est refusée →
                        // on retente en aperçu seul (1 flux, forme de la sonde).
                        CamLog.i("dual", "${cam.key} : repli sur le plan B (aperçu seul)")
                        runCatching { cam.reader?.close() }
                        cam.reader = null
                        configure(cam, 'B', ready)
                    } else {
                        ready(false)
                    }
                }
            },
            handler,
        )
    }

    /** Compte les images réellement délivrées par le capteur (preuve de vie). */
    private fun frameCounter(cam: Cam) = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            val n = cam.frames.incrementAndGet()
            if (n == 1) CamLog.i("dual", "${cam.key} : PREMIÈRE image reçue du capteur")
        }
    }

    // ------------------------------------------------------------------
    // Photo
    // ------------------------------------------------------------------

    /** Photo simultanée des deux caméras : arrière = recto, avant = verso. */
    fun capture(result: MethodChannel.Result) {
        val reply = Reply(result)
        if (!active) return reply.error("NOT_OPEN", "Double flux non ouvert")
        CamLog.i("dual", "capture des deux faces demandée")

        val files = HashMap<String, File?>()
        var done = 0
        fun collect(key: String, file: File?) {
            if (file == null) {
                CamLog.e("dual", "$key : capture échouée")
                reply.error("CAPTURE_FAILED", "Capture $key échouée (voir le journal)")
                return
            }
            files[key] = file
            done++
            CamLog.i("dual", "$key : photo écrite (${file.length() / 1024} Ko)")
            if (done == 2) {
                reply.success(
                    mapOf(
                        "back" to files["dualBack"]?.path,
                        "front" to files["dualFront"]?.path,
                    ),
                )
            }
        }
        captureOne(cams["dualBack"]) { collect("dualBack", it) }
        captureOne(cams["dualFront"]) { collect("dualFront", it) }
    }

    private fun captureOne(cam: Cam?, onFile: (File?) -> Unit) {
        if (cam == null) return onFile(null)
        if (!cam.hasReader) {
            // Plan B : pas de flux photo dans la session → on reconfigure la
            // session le temps du cliché, puis on rend l'aperçu.
            captureByReconfig(cam, onFile)
            return
        }
        val device = cam.device ?: return onFile(null)
        val session = cam.session ?: return onFile(null)
        val reader = cam.reader ?: return onFile(null)
        shoot(cam, device, session, reader, onFile)
    }

    /** Déclenche un JPEG sur un ImageReader déjà présent dans la session. */
    private fun shoot(
        cam: Cam,
        device: CameraDevice,
        session: CameraCaptureSession,
        reader: ImageReader,
        onFile: (File?) -> Unit,
    ) {
        var delivered = false
        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                if (delivered) return@setOnImageAvailableListener
                delivered = true
                val buffer = image.planes[0].buffer
                val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
                val file = File.createTempFile("nv_${cam.key}_", ".jpg", activity.cacheDir)
                FileOutputStream(file).use { it.write(bytes) }
                onFile(file)
            } catch (e: Exception) {
                CamLog.e("dual", "${cam.key} : écriture du JPEG impossible", e)
                onFile(null)
            } finally {
                image.close()
            }
        }, handler)

        val request = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
            addTarget(reader.surface)
            // Oriente le JPEG à l'endroit (EXIF), comme CameraX en mode simple.
            val orientation =
                if (cam.back) cam.sensorOrientation else (360 - cam.sensorOrientation) % 360
            set(CaptureRequest.JPEG_ORIENTATION, orientation)
        }
        runCatching { session.capture(request.build(), null, handler) }
            .onFailure {
                CamLog.e("dual", "${cam.key} : déclenchement refusé", it)
                onFile(null)
            }
    }

    /**
     * Plan B : la session ne contient que l'aperçu. On la remplace par une
     * session aperçu + JPEG le temps du cliché, puis on remet l'aperçu seul.
     * L'aperçu se fige ~300 ms, mais la photo est prise.
     */
    @Suppress("DEPRECATION")
    private fun captureByReconfig(cam: Cam, onFile: (File?) -> Unit) {
        val device = cam.device ?: return onFile(null)
        val previewSurface = cam.previewSurface ?: return onFile(null)
        CamLog.i("dual", "${cam.key} : capture par reconfiguration (plan B)")
        val reader = ImageReader.newInstance(
            previewSize.width, previewSize.height, ImageFormat.JPEG, 2,
        )
        runCatching { cam.session?.close() }
        device.createCaptureSession(
            listOf(previewSurface, reader.surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    cam.session = session
                    cam.reader = reader
                    shoot(cam, device, session, reader) { file ->
                        onFile(file)
                        // Retour à l'aperçu seul (1 flux) pour tenir le duo.
                        cam.reader = null
                        runCatching { reader.close() }
                        configure(cam, 'B') { ok ->
                            CamLog.i("dual", "${cam.key} : aperçu restauré (ok=$ok)")
                        }
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    CamLog.e(
                        "dual",
                        "${cam.key} : session de capture refusée — le matériel ne veut pas " +
                            "aperçu+photo en double flux",
                    )
                    runCatching { reader.close() }
                    onFile(null)
                }
            },
            handler,
        )
    }

    // ------------------------------------------------------------------
    // Fermeture
    // ------------------------------------------------------------------

    fun close() {
        if (active || cams.isNotEmpty()) CamLog.i("dual", "fermeture du double flux")
        closeInternal()
    }

    private fun closeInternal() {
        active = false
        cams.values.forEach { cam ->
            runCatching { cam.session?.close() }
            runCatching { cam.device?.close() }
            runCatching { cam.reader?.close() }
            // SurfaceProducer = objet Flutter : libération sur le thread UI.
            val producer = cam.producer
            if (producer != null) onUi { runCatching { producer.release() } }
        }
        cams.clear()
        backTextureId = -1
        frontTextureId = -1
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun firstCamera(facing: Int): String? =
        manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.LENS_FACING) == facing
        }

    private fun errorName(error: Int): String = when (error) {
        CameraDevice.StateCallback.ERROR_CAMERA_IN_USE -> "caméra déjà utilisée"
        CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> "trop de caméras ouvertes"
        CameraDevice.StateCallback.ERROR_CAMERA_DISABLED -> "caméra désactivée par la politique"
        CameraDevice.StateCallback.ERROR_CAMERA_DEVICE -> "erreur matérielle"
        CameraDevice.StateCallback.ERROR_CAMERA_SERVICE -> "erreur du service caméra"
        else -> "inconnue"
    }
}
