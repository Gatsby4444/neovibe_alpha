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
 * « non » sur le Redmi Note 10 Pro alors que le matériel, lui, accepte).
 *
 * ## Ce que les journaux de Jay ont établi (v0.8.0 → v0.8.5)
 *
 * 1. **Toute API Flutter (TextureRegistry, SurfaceProducer, MethodChannel) est
 *    `@UiThread`** : les callbacks Camera2 arrivant sur un thread secondaire,
 *    il faut repasser par `runOnUiThread`. (Crash v0.8.2.)
 * 2. **Une réponse de canal, une seule fois** — sinon « Reply already
 *    submitted » tue l'app. (Crash de la capture, v0.8.4.)
 * 3. **Une session qui se configure ne prouve RIEN** : en 2 flux/caméra 720p,
 *    la session de la frontale se configure, la requête est acceptée, et zéro
 *    image n'arrive. **Seul le compteur d'images fait foi.**
 * 4. **Ce qui MARCHE sur le Redmi : 1 flux par caméra en 720p** — les deux
 *    capteurs livrent en parallèle (≈30 et ≈17 images/s).
 * 5. **Ne JAMAIS reconfigurer les deux caméras en même temps** : le service
 *    caméra n'arrive pas à vider ses tampons (« Error waiting to drain :
 *    Connection timed out ») et casse les deux flux. Les captures se font donc
 *    **l'une après l'autre**, sur le thread caméra (jamais le thread principal :
 *    `createCaptureSession` y bloquait 5 s).
 *
 * ## Échelle de configurations
 *
 * Essayées dans l'ordre, la première qui **livre réellement des images sur les
 * deux caméras** gagne. La gagnante est **mémorisée** : les ouvertures
 * suivantes la retentent en premier (sinon on repaie le prix des essais ratés
 * à chaque entrée dans le Oneshot).
 */
@SuppressLint("MissingPermission") // permission caméra déjà accordée
class Camera2Dual(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    private val previewInfoSink: (key: String, w: Int, h: Int, rot: Int) -> Unit,
) {
    private val manager =
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private val prefs =
        activity.getSharedPreferences("neovibe_camera", Context.MODE_PRIVATE)

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
     * Numéro de l'essai en cours : les callbacks d'un essai abandonné peuvent
     * encore arriver — on les ignore, sinon ils font sauter des barreaux.
     */
    private var epoch = 0

    /**
     * Une configuration à tester. [photo] non nul = un ImageReader JPEG est
     * dans la session (2 flux/caméra) → capture des deux faces au MÊME instant.
     * [photo] nul = 1 flux/caméra → capture par reconfiguration séquentielle.
     */
    private data class Config(val preview: Size, val photo: Size?, val label: String)

    private val configs = listOf(
        Config(
            Size(1280, 720), Size(640, 480),
            "2 flux/caméra : aperçu 720p + photo 640×480 (capture simultanée)",
        ),
        Config(Size(1280, 720), null, "1 flux/caméra en 720p"),
        Config(Size(640, 480), null, "1 flux/caméra en 640×480"),
        Config(
            Size(1280, 720), Size(1280, 720),
            "2 flux/caméra : aperçu 720p + photo 720p",
        ),
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
    }

    /** Garantit une réponse unique au canal. */
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
        val backId = firstCamera(CameraCharacteristics.LENS_FACING_BACK)
        val frontId = firstCamera(CameraCharacteristics.LENS_FACING_FRONT)
        CamLog.i("dual", "caméras : arrière=$backId avant=$frontId")
        if (backId == null || frontId == null) {
            reply.error("DUAL_UNSUPPORTED", "Caméra avant ou arrière introuvable")
            return
        }

        // La configuration qui a marché la dernière fois passe en tête : on ne
        // repaie pas les essais ratés à chaque entrée dans le Oneshot.
        val known = prefs.getInt(PREF_CONFIG, -1)
        val order = configs.indices.sortedBy { if (it == known) -1 else it }
        if (known in configs.indices) {
            CamLog.i("dual", "configuration mémorisée : « ${configs[known].label} » → essayée en premier")
        }
        tryConfig(order, 0, backId, frontId, reply, mutableListOf())
    }

    /** Essaie la configuration [order]\[[step]] ; en cas d'échec, la suivante. */
    private fun tryConfig(
        order: List<Int>,
        step: Int,
        backId: String,
        frontId: String,
        reply: Reply,
        failures: MutableList<String>,
    ) {
        if (step >= order.size) {
            closeInternal()
            reply.error(
                "DUAL_UNSUPPORTED",
                "Aucune configuration ne tient : ${failures.joinToString(" ; ")}",
            )
            return
        }
        val index = order[step]
        val config = configs[index]
        CamLog.i("dual", "--- essai ${step + 1}/${order.size} : ${config.label} ---")

        try {
            closeInternal() // repart d'un état propre à chaque essai
            val mine = ++epoch
            thread = HandlerThread("nv-cam2-dual").also { it.start() }
            handler = Handler(thread!!.looper)

            fun next(reason: String) {
                if (mine != epoch) return // callback d'un essai déjà abandonné
                CamLog.e("dual", "essai ${step + 1} abandonné : $reason")
                failures += "${config.label} → $reason"
                closeInternal()
                onUi { tryConfig(order, step + 1, backId, frontId, reply, failures) }
            }

            // Arrière seule d'abord : ouvrir les deux d'un coup fait évincer.
            openCam("dualBack", backId, back = true, config = config) { backOk ->
                if (!backOk) return@openCam next("la caméra arrière n'a pas démarré")
                handler?.postDelayed({
                    val backAlone = cams["dualBack"]?.frames?.get() ?: 0
                    CamLog.i("dual", "arrière seule : $backAlone images en 600 ms")
                    if (backAlone == 0) {
                        return@postDelayed next("l'arrière ne délivre aucune image")
                    }
                    onUi { // createSurfaceProducer = THREAD PRINCIPAL
                        openCam("dualFront", frontId, back = false, config = config) { frontOk ->
                            if (!frontOk) {
                                return@openCam next("la caméra frontale n'a pas démarré")
                            }
                            verifyBoth(index, config, backAlone, reply, ::next)
                        }
                    }
                }, 600)
            }
        } catch (e: Exception) {
            CamLog.e("dual", "exception pendant l'essai ${step + 1}", e)
            failures += "${config.label} → ${e.javaClass.simpleName}: ${e.message}"
            closeInternal()
            onUi { tryConfig(order, step + 1, backId, frontId, reply, failures) }
        }
    }

    /**
     * Les deux caméras doivent **livrer des images en même temps**. Contrôle à
     * 500 ms (abandon immédiat si la frontale est encore à zéro : c'est le
     * symptôme du flux affamé) puis verdict à 1200 ms.
     */
    private fun verifyBoth(
        index: Int,
        config: Config,
        backAlone: Int,
        reply: Reply,
        next: (String) -> Unit,
    ) {
        val back = cams["dualBack"]
        val front = cams["dualFront"]
        val backBefore = back?.frames?.get() ?: 0

        handler?.postDelayed({
            val backNow = (back?.frames?.get() ?: 0) - backBefore
            val frontNow = front?.frames?.get() ?: 0
            CamLog.i("dual", "à 700 ms : arrière +$backNow | frontale $frontNow")
            if (frontNow == 0) {
                // Flux affamé : inutile d'attendre, on descend d'un barreau.
                return@postDelayed next("la frontale ne délivre aucune image (flux affamé)")
            }
        }, 700)

        handler?.postDelayed({
            val backAfter = (back?.frames?.get() ?: 0) - backBefore
            val frontFrames = front?.frames?.get() ?: 0
            val evicted = back?.evicted == true || front?.evicted == true
            val report =
                "${config.label} | arrière seule=$backAlone | arrière avec la frontale=$backAfter | " +
                    "frontale=$frontFrames | éviction=$evicted"
            CamLog.i("dual", "VÉRIFICATION 1200 ms → $report")

            if (evicted || backAfter < 4 || frontFrames < 4) {
                return@postDelayed next(
                    "flux non tenus ensemble (arrière=$backAfter, frontale=$frontFrames" +
                        (if (evicted) ", ÉVICTION" else "") + ")",
                )
            }

            active = true
            lastReport = report
            prefs.edit().putInt(PREF_CONFIG, index).apply()
            CamLog.i("dual", "SUCCÈS avec « ${config.label} » (mémorisée pour les prochaines fois)")
            reply.success(
                mapOf(
                    "backTextureId" to backTextureId,
                    "frontTextureId" to frontTextureId,
                    "report" to report,
                    "simultaneous" to (config.photo != null),
                ),
            )
        }, 1200)
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
        producer.setSize(config.preview.width, config.preview.height)
        cam.producer = producer
        // setSize AVANT getSurface, et sur le thread principal : la Surface est
        // ensuite utilisable telle quelle depuis le thread caméra.
        cam.previewSurface = producer.surface
        if (back) backTextureId = producer.id() else frontTextureId = producer.id()
        CamLog.i(
            "dual",
            "$key : ouverture caméra $id (capteur ${cam.sensorOrientation}°, " +
                "texture ${producer.id()}, aperçu ${config.preview.width}×${config.preview.height})",
        )

        previewInfoSink(key, config.preview.width, config.preview.height, cam.sensorOrientation)

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
                    configure(cam, withPhoto = config.photo != null, ready = ::ready)
                }

                override fun onDisconnected(device: CameraDevice) {
                    CamLog.e("dual", "$key : ÉVINCÉE (onDisconnected) — le matériel a coupé ce flux")
                    cam.evicted = true
                    active = false
                    runCatching { device.close() }
                    ready(false)
                }

                override fun onError(device: CameraDevice, error: Int) {
                    CamLog.e("dual", "$key : erreur $error (${errorName(error)})")
                    cam.evicted = true
                    active = false
                    runCatching { device.close() }
                    ready(false)
                }
            },
            handler,
        )
    }

    /** Configure la session : aperçu, plus le flux photo si la config en a un. */
    @Suppress("DEPRECATION")
    private fun configure(cam: Cam, withPhoto: Boolean, ready: (Boolean) -> Unit) {
        val device = cam.device ?: return ready(false)
        val previewSurface = cam.previewSurface ?: return ready(false)

        val targets = mutableListOf(previewSurface)
        if (withPhoto) {
            val photo = cam.config.photo ?: Size(640, 480)
            val reader = ImageReader.newInstance(
                photo.width, photo.height, ImageFormat.JPEG, 2,
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
    // Photo — arrière = recto, avant = verso
    // ------------------------------------------------------------------

    fun capture(result: MethodChannel.Result) {
        val reply = Reply(result)
        val back = cams["dualBack"]
        val front = cams["dualFront"]
        if (!active || back == null || front == null) {
            return reply.error("NOT_OPEN", "Double flux non ouvert")
        }
        CamLog.i("dual", "capture des deux faces demandée")

        // TOUT se passe sur le thread caméra : createCaptureSession bloque
        // plusieurs secondes et gelait le thread principal (journal du
        // 2026-07-14). Et les caméras sont traitées L'UNE APRÈS L'AUTRE : les
        // reconfigurer ensemble casse le service caméra (« error waiting to
        // drain »).
        handler?.post {
            try {
                captureOne(back) { backFile ->
                    if (backFile == null) {
                        return@captureOne fail(reply, "capture arrière impossible")
                    }
                    captureOne(front) { frontFile ->
                        if (frontFile == null) {
                            return@captureOne fail(reply, "capture frontale impossible")
                        }
                        CamLog.i("dual", "deux faces capturées")
                        reply.success(
                            mapOf("back" to backFile.path, "front" to frontFile.path),
                        )
                    }
                }
            } catch (e: Exception) {
                CamLog.e("dual", "exception pendant la capture", e)
                fail(reply, "${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /**
     * Une capture ratée laisse souvent le matériel dans un état bancal : on
     * ferme tout, le Dart repasse en vue simple (qui, elle, marche toujours).
     */
    private fun fail(reply: Reply, reason: String) {
        closeInternal()
        reply.error("CAPTURE_FAILED", reason)
    }

    private fun captureOne(cam: Cam, onFile: (File?) -> Unit) {
        val device = cam.device ?: return onFile(null)
        val reader = cam.reader
        if (reader != null) {
            // Le flux photo est déjà dans la session : déclenchement immédiat.
            val session = cam.session ?: return onFile(null)
            shoot(cam, device, session, reader, onFile)
        } else {
            captureByReconfig(cam, onFile)
        }
    }

    /** Déclenche un JPEG sur un ImageReader présent dans la session. */
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
                CamLog.i("dual", "${cam.key} : photo écrite (${file.length() / 1024} Ko)")
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
     * Config à 1 flux : on remplace la session (aperçu) par une session
     * aperçu + JPEG le temps du cliché, puis on remet l'aperçu seul. L'aperçu
     * de CETTE caméra se fige ~500 ms ; l'autre continue.
     *
     * `stopRepeating` + `abortCaptures` AVANT de fermer la session : sans ça,
     * le service caméra n'arrive pas à vider ses tampons pendant que l'autre
     * caméra tourne (« Error waiting to drain », qui a cassé les deux flux).
     */
    @Suppress("DEPRECATION")
    private fun captureByReconfig(cam: Cam, onFile: (File?) -> Unit) {
        val device = cam.device ?: return onFile(null)
        val previewSurface = cam.previewSurface ?: return onFile(null)
        CamLog.i("dual", "${cam.key} : capture par reconfiguration de la session")

        runCatching {
            cam.session?.stopRepeating()
            cam.session?.abortCaptures()
        }.onFailure { CamLog.e("dual", "${cam.key} : arrêt du flux répétitif", it) }
        runCatching { cam.session?.close() }

        val reader = ImageReader.newInstance(640, 480, ImageFormat.JPEG, 2)
        device.createCaptureSession(
            listOf(previewSurface, reader.surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    cam.session = session
                    cam.reader = reader
                    shoot(cam, device, session, reader) { file ->
                        // On rend l'aperçu AVANT de répondre : la caméra suivante
                        // doit trouver un matériel au repos.
                        cam.reader = null
                        runCatching { reader.close() }
                        configure(cam, withPhoto = false) { ok ->
                            CamLog.i("dual", "${cam.key} : aperçu restauré (ok=$ok)")
                            onFile(file)
                        }
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    CamLog.e("dual", "${cam.key} : session de capture refusée")
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
        epoch++ // invalide les callbacks en vol
        cams.values.forEach { cam ->
            runCatching { cam.session?.stopRepeating() }
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

    private companion object {
        const val PREF_CONFIG = "dual_config_index"
    }
}
