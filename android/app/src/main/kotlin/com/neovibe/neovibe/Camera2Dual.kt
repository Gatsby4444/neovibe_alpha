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
import android.util.Size
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
 * ## Règles apprises à la dure (v0.8.0 → v0.8.4)
 *
 * 1. **Tout ce qui touche à Flutter (TextureRegistry, SurfaceProducer,
 *    MethodChannel) DOIT s'exécuter sur le thread principal** (elles sont
 *    annotées `@UiThread`). Les callbacks Camera2 arrivent, eux, sur un thread
 *    secondaire : repasser par `runOnUiThread` avant de toucher à Flutter.
 *    C'était la cause du crash v0.8.2.
 * 2. **Une réponse de canal, une seule fois** (`Reply`) : répondre deux fois à
 *    un `MethodChannel.Result` lève « Reply already submitted » et tue l'app.
 * 3. **Ouverture séquentielle** (arrière, puis frontale).
 * 4. **Une session qui se configure ne prouve RIEN** : sur le Redmi (journal du
 *    2026-07-14), la session de la frontale se configure, la requête répétitive
 *    est acceptée… et **zéro image** n'arrive, pendant que l'arrière tombe de
 *    11 à 3 images/s. Le matériel accepte la configuration puis affame le
 *    second flux. **Seul le compteur d'images fait foi.**
 * 5. **Toujours libérer** : une caméra laissée ouverte verrouille le matériel
 *    (« Available cameras: 0 » jusqu'au redémarrage).
 *
 * ## Échelle de configurations (essayées dans l'ordre, la 1re qui LIVRE gagne)
 *
 * La sonde qui a réussi ouvrait **1 flux par caméra en 640×480**. La v0.8.3
 * demandait **2 flux par caméra en 720p** (aperçu + photo) : trop gourmand →
 * la frontale n'était pas alimentée. On part donc du plus léger et on ne monte
 * que si ça tient. Le journal indique la configuration retenue.
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

    /**
     * Numéro de l'essai en cours. Les callbacks d'un essai abandonné peuvent
     * encore arriver (messages déjà partis sur le thread caméra) : on les
     * ignore, sinon ils font sauter deux barreaux d'un coup dans l'échelle.
     */
    private var epoch = 0

    /**
     * Une configuration à tester. [streams] = nombre de flux par caméra
     * (1 = aperçu seul, la photo passera par une reconfiguration ponctuelle ;
     * 2 = aperçu + ImageReader JPEG, plus confortable mais plus gourmand).
     */
    private data class Config(val streams: Int, val size: Size, val label: String)

    private val configs = listOf(
        Config(1, Size(1280, 720), "1 flux/caméra en 720p"),
        Config(1, Size(640, 480), "1 flux/caméra en 640×480 (config validée par la sonde)"),
        Config(2, Size(1280, 720), "2 flux/caméra en 720p (aperçu + photo)"),
    )

    /** État d'une caméra du duo. */
    private inner class Cam(
        val key: String,
        val id: String,
        val back: Boolean,
        val config: Config,
    ) {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var producer: TextureRegistry.SurfaceProducer? = null

        /** Surface de la texture Flutter, récupérée sur le THREAD PRINCIPAL. */
        var previewSurface: Surface? = null
        var reader: ImageReader? = null
        var sensorOrientation = 0

        /** Images réellement délivrées par le capteur : la seule preuve de vie. */
        val frames = AtomicInteger(0)
        var evicted = false

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
    // Ouverture : on descend l'échelle des configurations
    // ------------------------------------------------------------------

    fun open(result: MethodChannel.Result) {
        val reply = Reply(result)
        CamLog.i("dual", "=== OUVERTURE DOUBLE FLUX (Camera2 brut) ===")
        val backId = firstCamera(CameraCharacteristics.LENS_FACING_BACK)
        val frontId = firstCamera(CameraCharacteristics.LENS_FACING_FRONT)
        CamLog.i(
            "dual",
            "caméras : arrière=$backId avant=$frontId (liste=${manager.cameraIdList.joinToString()})",
        )
        if (backId == null || frontId == null) {
            reply.error("DUAL_UNSUPPORTED", "Caméra avant ou arrière introuvable")
            return
        }
        tryConfig(0, backId, frontId, reply, mutableListOf())
    }

    /** Essaie la configuration [index] ; en cas d'échec, passe à la suivante. */
    private fun tryConfig(
        index: Int,
        backId: String,
        frontId: String,
        reply: Reply,
        failures: MutableList<String>,
    ) {
        if (index >= configs.size) {
            closeInternal()
            reply.error(
                "DUAL_UNSUPPORTED",
                "Aucune configuration ne tient : ${failures.joinToString(" ; ")}",
            )
            return
        }
        val config = configs[index]
        CamLog.i("dual", "--- essai ${index + 1}/${configs.size} : ${config.label} ---")

        try {
            closeInternal() // repart d'un état propre à chaque essai
            val mine = ++epoch
            thread = HandlerThread("nv-cam2-dual").also { it.start() }
            handler = Handler(thread!!.looper)

            fun next(reason: String) {
                if (mine != epoch) return // callback d'un essai déjà abandonné
                CamLog.e("dual", "essai ${index + 1} abandonné : $reason")
                failures += "${config.label} → $reason"
                closeInternal()
                onUi { tryConfig(index + 1, backId, frontId, reply, failures) }
            }

            // 1) Arrière seule d'abord (ouvrir les deux d'un coup fait évincer).
            openCam("dualBack", backId, back = true, config = config) { backOk ->
                if (!backOk) return@openCam next("la caméra arrière n'a pas démarré")
                handler?.postDelayed({
                    val backAlone = cams["dualBack"]?.frames?.get() ?: 0
                    CamLog.i("dual", "arrière seule : $backAlone images en 700 ms")
                    if (backAlone == 0) {
                        return@postDelayed next("l'arrière ne délivre aucune image")
                    }
                    // 2) Frontale — createSurfaceProducer = THREAD PRINCIPAL.
                    onUi {
                        openCam("dualFront", frontId, back = false, config = config) { frontOk ->
                            if (!frontOk) {
                                return@openCam next("la caméra frontale n'a pas démarré")
                            }
                            verifyBoth(config, backAlone, reply, ::next)
                        }
                    }
                }, 700)
            }
        } catch (e: Exception) {
            CamLog.e("dual", "exception pendant l'essai ${index + 1}", e)
            failures += "${config.label} → ${e.javaClass.simpleName}: ${e.message}"
            closeInternal()
            onUi { tryConfig(index + 1, backId, frontId, reply, failures) }
        }
    }

    /**
     * Les deux caméras sont ouvertes : elles doivent **livrer des images toutes
     * les deux, en même temps**, pendant 1,5 s. Une session configurée ne prouve
     * rien (leçon du journal du 2026-07-14 : la frontale se configurait puis
     * restait à zéro image).
     */
    private fun verifyBoth(
        config: Config,
        backAlone: Int,
        reply: Reply,
        next: (String) -> Unit,
    ) {
        val back = cams["dualBack"]
        val front = cams["dualFront"]
        val backBefore = back?.frames?.get() ?: 0

        // Relevés intermédiaires : ils montrent si un flux démarre lentement
        // ou s'il ne démarre jamais.
        for (ms in listOf(500L, 1000L)) {
            handler?.postDelayed({
                CamLog.i(
                    "dual",
                    "à $ms ms : arrière +${(back?.frames?.get() ?: 0) - backBefore} | " +
                        "frontale ${front?.frames?.get() ?: 0}",
                )
            }, ms)
        }

        handler?.postDelayed({
            val backAfter = (back?.frames?.get() ?: 0) - backBefore
            val frontFrames = front?.frames?.get() ?: 0
            val evicted = back?.evicted == true || front?.evicted == true
            val report =
                "${config.label} | arrière seule=$backAlone | arrière avec la frontale=$backAfter | " +
                    "frontale=$frontFrames | éviction=$evicted"
            CamLog.i("dual", "VÉRIFICATION 1500 ms → $report")

            // Seuils : les deux doivent tourner à au moins ~3 images/s.
            if (evicted || backAfter < 5 || frontFrames < 5) {
                return@postDelayed next(
                    "flux non tenus ensemble (arrière=$backAfter, frontale=$frontFrames" +
                        (if (evicted) ", ÉVICTION" else "") + ")",
                )
            }

            active = true
            lastReport = report
            CamLog.i(
                "dual",
                "SUCCÈS avec « ${config.label} » — textures back=$backTextureId " +
                    "front=$frontTextureId. Si l'aperçu est NOIR alors que ces compteurs " +
                    "montent, le problème est le RENDU (texture Flutter), pas la caméra.",
            )
            reply.success(
                mapOf(
                    "backTextureId" to backTextureId,
                    "frontTextureId" to frontTextureId,
                    "report" to report,
                ),
            )
        }, 1500)
    }

    /**
     * Ouvre une caméra et configure sa session. **À appeler sur le thread
     * principal** (crée une texture Flutter et notifie le Dart).
     */
    private fun openCam(
        key: String,
        id: String,
        back: Boolean,
        config: Config,
        onReady: (Boolean) -> Unit,
    ) {
        val cam = Cam(key, id, back, config)
        cams[key] = cam
        cam.sensorOrientation = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

        val producer = textureRegistry.createSurfaceProducer()
        producer.setSize(config.size.width, config.size.height)
        cam.producer = producer
        // setSize AVANT getSurface, et sur le thread principal : la Surface est
        // ensuite utilisable telle quelle depuis le thread caméra.
        cam.previewSurface = producer.surface
        if (back) backTextureId = producer.id() else frontTextureId = producer.id()
        CamLog.i(
            "dual",
            "$key : ouverture caméra $id (capteur ${cam.sensorOrientation}°, " +
                "texture ${producer.id()}, aperçu ${config.size.width}×${config.size.height})",
        )

        // Le Dart doit connaître taille + rotation AVANT les premières images.
        previewInfoSink(key, config.size.width, config.size.height, cam.sensorOrientation)

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
                    configure(cam, ::ready)
                }

                override fun onDisconnected(device: CameraDevice) {
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

    /** Configure la session selon la config de l'essai en cours. */
    @Suppress("DEPRECATION")
    private fun configure(cam: Cam, ready: (Boolean) -> Unit) {
        val device = cam.device ?: return ready(false)
        val previewSurface = cam.previewSurface ?: return ready(false)
        val config = cam.config

        val targets = mutableListOf(previewSurface)
        if (config.streams >= 2) {
            val reader = ImageReader.newInstance(
                config.size.width, config.size.height, ImageFormat.JPEG, 2,
            )
            cam.reader = reader
            targets += reader.surface
        }
        CamLog.i("dual", "${cam.key} : session à ${targets.size} flux")

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
                    CamLog.i("dual", "${cam.key} : session configurée, aperçu démarré")
                    ready(true)
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    CamLog.e("dual", "${cam.key} : session REFUSÉE par le matériel")
                    runCatching { session.close() }
                    ready(false)
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
            // Config à 1 flux : pas de flux photo dans la session → on la
            // reconfigure le temps du cliché, puis on rend l'aperçu.
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
     * Config à 1 flux : la session ne contient que l'aperçu. On la remplace par
     * une session aperçu + JPEG le temps du cliché, puis on remet l'aperçu seul.
     * L'aperçu se fige ~300 ms, mais la photo est prise.
     */
    @Suppress("DEPRECATION")
    private fun captureByReconfig(cam: Cam, onFile: (File?) -> Unit) {
        val device = cam.device ?: return onFile(null)
        val previewSurface = cam.previewSurface ?: return onFile(null)
        CamLog.i("dual", "${cam.key} : capture par reconfiguration de la session")
        val reader = ImageReader.newInstance(
            cam.config.size.width, cam.config.size.height, ImageFormat.JPEG, 2,
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
                        configure(cam) { ok ->
                            CamLog.i("dual", "${cam.key} : aperçu restauré (ok=$ok)")
                        }
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    CamLog.e(
                        "dual",
                        "${cam.key} : session de capture refusée — le matériel ne veut pas " +
                            "aperçu+photo pendant le double flux",
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
