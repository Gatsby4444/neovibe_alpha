package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Double flux Oneshot — **UN SEUL FLUX PAR CAMÉRA, JAMAIS RECONFIGURÉ**.
 *
 * ## Pourquoi cette architecture (et pas une autre)
 *
 * Les journaux de Jay (Redmi Note 10 Pro, Android 13) ont établi, dans l'ordre :
 *
 * - Le matériel **accepte deux caméras ouvertes** avec **1 flux chacune en
 *   720p** : les deux capteurs livrent en parallèle (v0.8.4, mesuré).
 * - Il **refuse 2 flux par caméra** : la session se configure, la requête est
 *   acceptée… et la frontale ne reçoit **aucune image** (flux affamé). Le
 *   téléphone ne déclare pas `getConcurrentCameraIds()` : on est hors des
 *   combinaisons garanties par Android, le HAL fait ce qu'il veut.
 * - **Reconfigurer une session pendant que l'autre caméra tourne casse tout**
 *   (« waitUntilIdle: Error waiting to drain ») — et, pire, un essai raté
 *   laisse le **service caméra mort** : `getCameraCharacteristics` répond
 *   « unknown device 0 », `cameraIdList` devient VIDE, et plus aucune caméra
 *   ne s'ouvre jusqu'au redémarrage de l'app (v0.8.5).
 *
 * Conclusion : **on ne sonde plus, on ne reconfigure plus.** Une seule
 * configuration, celle qui marche, ouverte UNE fois. Et comme il est interdit
 * d'ajouter un flux photo, l'unique flux est un **ImageReader YUV** dont on
 * fait TOUT :
 *
 *  - **l'aperçu** : chaque image est convertie et dessinée dans la texture
 *    Flutter (rendu logiciel, [renderFrame]) ;
 *  - **la photo** : c'est la **dernière image reçue** ([lastFrame]) — donc une
 *    capture **instantanée et vraiment simultanée** des deux faces, sans
 *    toucher à la caméra.
 *
 * Rien, après l'ouverture, ne parle plus au service caméra jusqu'à la
 * fermeture. Il n'y a plus rien qui puisse le casser.
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

    /** Thread dédié à la FERMETURE (voir [close] : ni UI, ni thread caméra). */
    private val closer = java.util.concurrent.Executors.newSingleThreadExecutor()

    private val cams = mutableMapOf<String, Cam>()
    var backTextureId: Long = -1
        private set
    var frontTextureId: Long = -1
        private set
    var active = false
        private set
    var lastReport: String? = null
        private set

    /** La seule configuration que ce matériel tolère (mesurée, pas devinée). */
    private val previewSize = Size(1280, 720)

    /** Une image brute conservée pour la capture (dernière reçue). */
    private class Frame(val nv21: ByteArray, val width: Int, val height: Int)

    private inner class Cam(val key: String, val back: Boolean) {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var reader: ImageReader? = null
        var texture: TextureRegistry.SurfaceTextureEntry? = null
        var surface: Surface? = null
        var sensorOrientation = 0

        /** Images reçues : la seule preuve de vie d'un flux. */
        val frames = AtomicInteger(0)
        var evicted = false

        /** Un rendu est en cours : on saute l'image plutôt que d'empiler. */
        val rendering = AtomicBoolean(false)

        @Volatile
        var lastFrame: Frame? = null

        /** Fermeture réellement terminée (le service caméra a rendu la main). */
        val closed = CountDownLatch(1)
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
    // Ouverture — UNE seule tentative, UNE seule configuration
    // ------------------------------------------------------------------

    fun open(result: MethodChannel.Result) {
        val reply = Reply(result)
        CamLog.i("dual", "=== OUVERTURE DOUBLE FLUX (1 flux/caméra, rendu logiciel) ===")
        try {
            val ids = manager.cameraIdList
            val backId = firstCamera(CameraCharacteristics.LENS_FACING_BACK)
            val frontId = firstCamera(CameraCharacteristics.LENS_FACING_FRONT)
            CamLog.i("dual", "caméras : arrière=$backId avant=$frontId (liste=${ids.joinToString()})")
            if (backId == null || frontId == null) {
                // cameraIdList vide = service caméra tombé : ne RIEN tenter.
                reply.error(
                    "DUAL_UNSUPPORTED",
                    "Service caméra indisponible (aucune caméra listée)",
                )
                return
            }

            thread = HandlerThread("nv-cam2-dual").also { it.start() }
            handler = Handler(thread!!.looper)

            // Arrière d'abord, seule ; la frontale ensuite (ouvrir les deux en
            // même temps fait évincer la première).
            openCam("dualBack", backId, back = true) { backOk ->
                if (!backOk) {
                    closeAndReply(reply, "la caméra arrière n'a pas démarré")
                    return@openCam
                }
                handler?.postDelayed({
                    val alone = cams["dualBack"]?.frames?.get() ?: 0
                    CamLog.i("dual", "arrière seule : $alone images en 600 ms")
                    if (alone == 0) {
                        closeAndReply(reply, "l'arrière ne délivre aucune image")
                        return@postDelayed
                    }
                    onUi {
                        openCam("dualFront", frontId, back = false) { frontOk ->
                            if (!frontOk) {
                                closeAndReply(reply, "la caméra frontale n'a pas démarré")
                                return@openCam
                            }
                            verify(alone, reply)
                        }
                    }
                }, 600)
            }
        } catch (e: Exception) {
            CamLog.e("dual", "exception à l'ouverture", e)
            closeAndReply(reply, "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /** Les deux caméras doivent livrer des images EN MÊME TEMPS. */
    private fun verify(backAlone: Int, reply: Reply) {
        val back = cams["dualBack"]
        val front = cams["dualFront"]
        val before = back?.frames?.get() ?: 0
        handler?.postDelayed({
            val backAfter = (back?.frames?.get() ?: 0) - before
            val frontFrames = front?.frames?.get() ?: 0
            val evicted = back?.evicted == true || front?.evicted == true
            val report =
                "arrière seule=$backAlone | arrière avec la frontale=$backAfter | " +
                    "frontale=$frontFrames | éviction=$evicted"
            CamLog.i("dual", "VÉRIFICATION 1200 ms → $report")

            if (evicted || backAfter < 4 || frontFrames < 4) {
                closeAndReply(reply, "flux non tenus ensemble ($report)")
                return@postDelayed
            }

            active = true
            lastReport = report
            CamLog.i("dual", "SUCCÈS — double flux vivant, capture simultanée disponible")
            reply.success(
                mapOf(
                    "backTextureId" to backTextureId,
                    "frontTextureId" to frontTextureId,
                    "report" to report,
                    "simultaneous" to true,
                ),
            )
        }, 1200)
    }

    /**
     * Ouvre une caméra avec son unique flux (ImageReader YUV). **Thread
     * principal** (crée une texture Flutter et notifie le Dart).
     */
    private fun openCam(key: String, id: String, back: Boolean, onReady: (Boolean) -> Unit) {
        val cam = Cam(key, back)
        cams[key] = cam
        cam.sensorOrientation = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

        // Le capteur est monté « paysage » : on tourne l'image NOUS-MÊMES au
        // rendu, donc la texture est déjà en portrait et le Dart n'a plus
        // aucune rotation à appliquer (rotation = 0).
        val turned = cam.sensorOrientation % 180 != 0
        val outW = if (turned) previewSize.height else previewSize.width
        val outH = if (turned) previewSize.width else previewSize.height

        val entry = textureRegistry.createSurfaceTexture()
        entry.surfaceTexture().setDefaultBufferSize(outW, outH)
        cam.texture = entry
        cam.surface = Surface(entry.surfaceTexture())
        if (back) backTextureId = entry.id() else frontTextureId = entry.id()

        val reader = ImageReader.newInstance(
            previewSize.width, previewSize.height, ImageFormat.YUV_420_888, 2,
        )
        cam.reader = reader
        CamLog.i(
            "dual",
            "$key : caméra $id (capteur ${cam.sensorOrientation}°, texture ${entry.id()}, " +
                "flux YUV ${previewSize.width}×${previewSize.height} → aperçu ${outW}×$outH)",
        )
        previewInfoSink(key, outW, outH, 0)

        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val frame = Frame(toNv21(image), image.width, image.height)
                cam.lastFrame = frame // la photo, c'est celle-ci
                val n = cam.frames.incrementAndGet()
                if (n == 1) CamLog.i("dual", "$key : PREMIÈRE image reçue du capteur")
                // Rendu : on saute l'image si le précédent dessin n'est pas fini
                // (mieux vaut un aperçu à 15 images/s qu'une file qui s'empile).
                if (cam.rendering.compareAndSet(false, true)) {
                    try {
                        renderFrame(cam, frame, outW, outH)
                    } finally {
                        cam.rendering.set(false)
                    }
                }
            } catch (e: Exception) {
                CamLog.e("dual", "$key : image ignorée", e)
            } finally {
                image.close()
            }
        }, handler)

        var settled = false
        fun ready(ok: Boolean) {
            if (settled) return
            settled = true
            onUi { onReady(ok) }
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
                    CamLog.e("dual", "$key : ÉVINCÉE (onDisconnected)")
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

                override fun onClosed(device: CameraDevice) {
                    CamLog.i("dual", "$key : caméra refermée (matériel rendu)")
                    cam.closed.countDown()
                }
            },
            handler,
        )
    }

    /** Session à UN SEUL flux : l'ImageReader. Aucune reconfiguration ensuite. */
    @Suppress("DEPRECATION")
    private fun configure(cam: Cam, ready: (Boolean) -> Unit) {
        val device = cam.device ?: return ready(false)
        val reader = cam.reader ?: return ready(false)
        device.createCaptureSession(
            listOf(reader.surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    cam.session = session
                    val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                        .apply { addTarget(reader.surface) }
                    runCatching { session.setRepeatingRequest(request.build(), null, handler) }
                        .onFailure {
                            CamLog.e("dual", "${cam.key} : flux répétitif refusé", it)
                            return ready(false)
                        }
                    CamLog.i("dual", "${cam.key} : session configurée (1 flux)")
                    ready(true)
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    CamLog.e("dual", "${cam.key} : session REFUSÉE")
                    runCatching { session.close() }
                    ready(false)
                }
            },
            handler,
        )
    }

    // ------------------------------------------------------------------
    // Rendu logiciel de l'aperçu
    // ------------------------------------------------------------------

    /**
     * Convertit l'image YUV en bitmap (sous-échantillonné : l'aperçu n'a pas
     * besoin du plein format) et la dessine, déjà pivotée, dans la texture
     * Flutter. Tourne sur le thread caméra, jamais sur le thread principal.
     */
    private fun renderFrame(cam: Cam, frame: Frame, outW: Int, outH: Int) {
        val surface = cam.surface ?: return
        if (!surface.isValid) return
        val bitmap = decode(frame, sample = 2) ?: return
        val canvas = runCatching { surface.lockCanvas(null) }.getOrNull()
        if (canvas == null) {
            // Le rendu logiciel est impossible sur cette surface : on le dit
            // clairement dans le journal (sinon l'aperçu serait « noir » sans
            // explication, l'erreur que j'ai mis trois versions à voir).
            CamLog.e("dual", "${cam.key} : lockCanvas a échoué — aperçu impossible")
            bitmap.recycle()
            return
        }
        try {
            val matrix = Matrix().apply {
                postRotate(
                    cam.sensorOrientation.toFloat(),
                    bitmap.width / 2f,
                    bitmap.height / 2f,
                )
                // Après rotation, l'image est centrée sur l'ancien repère :
                // on la ramène en (0,0) puis on l'étire au format de sortie.
                val turned = cam.sensorOrientation % 180 != 0
                val rotW = if (turned) bitmap.height else bitmap.width
                val rotH = if (turned) bitmap.width else bitmap.height
                postTranslate((rotW - bitmap.width) / 2f, (rotH - bitmap.height) / 2f)
                postScale(outW / rotW.toFloat(), outH / rotH.toFloat())
            }
            canvas.drawBitmap(bitmap, matrix, Paint(Paint.FILTER_BITMAP_FLAG))
        } finally {
            runCatching { surface.unlockCanvasAndPost(canvas) }
            bitmap.recycle()
        }
    }

    /** YUV → bitmap, en passant par le JPEG (chemin matériel le plus rapide). */
    private fun decode(frame: Frame, sample: Int, quality: Int = 80): Bitmap? {
        val out = ByteArrayOutputStream()
        YuvImage(frame.nv21, ImageFormat.NV21, frame.width, frame.height, null)
            .compressToJpeg(Rect(0, 0, frame.width, frame.height), quality, out)
        val bytes = out.toByteArray()
        return BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample },
        )
    }

    /** Plans YUV_420_888 → NV21 (format d'entrée de YuvImage). */
    private fun toNv21(image: Image): ByteArray {
        val width = image.width
        val height = image.height
        val out = ByteArray(width * height * 3 / 2)

        val yPlane = image.planes[0]
        val yBuffer = yPlane.buffer
        var pos = 0
        if (yPlane.rowStride == width) {
            yBuffer.get(out, 0, width * height)
            pos = width * height
        } else {
            val row = ByteArray(yPlane.rowStride)
            for (y in 0 until height) {
                yBuffer.position(y * yPlane.rowStride)
                yBuffer.get(row, 0, minOf(row.size, yBuffer.remaining()))
                System.arraycopy(row, 0, out, pos, width)
                pos += width
            }
        }

        // NV21 = Y puis VU entrelacé.
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (y in 0 until chromaHeight) {
            for (x in 0 until chromaWidth) {
                val uvIndex = y * uPlane.rowStride + x * uPlane.pixelStride
                out[pos++] = vBuffer.get(y * vPlane.rowStride + x * vPlane.pixelStride)
                out[pos++] = uBuffer.get(uvIndex)
            }
        }
        return out
    }

    // ------------------------------------------------------------------
    // Photo — la dernière image reçue : instantanée, aucune action caméra
    // ------------------------------------------------------------------

    fun capture(result: MethodChannel.Result) {
        val reply = Reply(result)
        val back = cams["dualBack"]?.lastFrame
        val front = cams["dualFront"]?.lastFrame
        val backCam = cams["dualBack"]
        val frontCam = cams["dualFront"]
        if (!active || back == null || front == null || backCam == null || frontCam == null) {
            return reply.error("NOT_OPEN", "Double flux non ouvert")
        }
        CamLog.i("dual", "capture : les deux dernières images reçues (aucune action caméra)")
        // Les deux faces sont écrites EN PARALLÈLE (deux cœurs, deux images
        // indépendantes) : la capture Oneshot doit être quasi instantanée
        // (retour Jay, 2026-07-14).
        val started = System.currentTimeMillis()
        closer.execute {
            try {
                var backFile: File? = null
                var frontFile: File? = null
                val worker = Thread { frontFile = writeJpeg(frontCam, front) }
                worker.start()
                backFile = writeJpeg(backCam, back)
                worker.join(5000)

                val b = backFile
                val f = frontFile
                if (b == null || f == null) {
                    reply.error("CAPTURE_FAILED", "Écriture des faces impossible")
                    return@execute
                }
                CamLog.i(
                    "dual",
                    "deux faces écrites en ${System.currentTimeMillis() - started} ms",
                )
                reply.success(mapOf("back" to b.path, "front" to f.path))
            } catch (e: Exception) {
                CamLog.e("dual", "capture impossible", e)
                reply.error("CAPTURE_FAILED", "${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /**
     * Image brute → JPEG, **en un seul encodage**.
     *
     * La rotation n'est PAS cuite dans les pixels ici (décoder + tourner +
     * ré-encoder coûtait ~350 ms par face) : elle est posée en **métadonnée
     * EXIF**, et la normalisation qui suit (`normalize` côté NativeCamera —
     * recadrage 9:16 + mise au format des cards) l'applique au passage, sans
     * décodage supplémentaire.
     */
    private fun writeJpeg(cam: Cam, frame: Frame): File? = try {
        val out = ByteArrayOutputStream()
        YuvImage(frame.nv21, ImageFormat.NV21, frame.width, frame.height, null)
            .compressToJpeg(Rect(0, 0, frame.width, frame.height), 92, out)
        val file = File.createTempFile("nv_${cam.key}_", ".jpg", activity.cacheDir)
        FileOutputStream(file).use { it.write(out.toByteArray()) }
        ExifInterface(file.path).apply {
            setAttribute(
                ExifInterface.TAG_ORIENTATION,
                when (cam.sensorOrientation) {
                    90 -> ExifInterface.ORIENTATION_ROTATE_90
                    180 -> ExifInterface.ORIENTATION_ROTATE_180
                    270 -> ExifInterface.ORIENTATION_ROTATE_270
                    else -> ExifInterface.ORIENTATION_NORMAL
                }.toString(),
            )
            saveAttributes()
        }
        CamLog.i("dual", "${cam.key} : photo écrite (${file.length() / 1024} Ko)")
        file
    } catch (e: Exception) {
        CamLog.e("dual", "${cam.key} : écriture impossible", e)
        null
    }

    // ------------------------------------------------------------------
    // Fermeture — on ATTEND que le matériel soit rendu
    // ------------------------------------------------------------------

    private fun closeAndReply(reply: Reply, reason: String) {
        close { reply.error("DUAL_UNSUPPORTED", reason) }
    }

    /**
     * Ferme tout et **attend la confirmation d'Android** (`onClosed`) avant
     * d'appeler [onDone]. Sans cette attente, la pile suivante (CameraX) rouvre
     * sur un service qui n'a pas fini de rendre le matériel → « Available
     * cameras: 0 », puis « unknown device » (v0.8.5).
     *
     * L'attente se fait sur un thread À PART : ni le thread principal (ANR),
     * ni le thread caméra (c'est LUI qui délivre `onClosed` → interblocage).
     */
    fun close(onDone: (() -> Unit)? = null) {
        val pending = cams.values.toList()
        cams.clear()
        active = false
        backTextureId = -1
        frontTextureId = -1
        val camThread = thread
        thread = null
        handler = null

        if (pending.isEmpty()) {
            onUi { onDone?.invoke() }
            return
        }
        CamLog.i("dual", "fermeture du double flux")
        pending.forEach { cam ->
            runCatching { cam.session?.stopRepeating() }
            runCatching { cam.session?.close() }
            runCatching { cam.device?.close() }
        }
        closer.execute {
            pending.forEach { cam ->
                val done = runCatching { cam.closed.await(1500, TimeUnit.MILLISECONDS) }
                    .getOrDefault(false)
                if (!done) CamLog.e("dual", "${cam.key} : fermeture non confirmée après 1,5 s")
                runCatching { cam.reader?.close() }
                runCatching { cam.surface?.release() }
            }
            camThread?.quitSafely()
            CamLog.i("dual", "double flux fermé, matériel rendu")
            onUi {
                pending.forEach { cam -> runCatching { cam.texture?.release() } }
                onDone?.invoke()
            }
        }
    }

    private fun firstCamera(facing: Int): String? =
        manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.LENS_FACING) == facing
        }

    private fun errorName(error: Int): String = when (error) {
        CameraDevice.StateCallback.ERROR_CAMERA_IN_USE -> "caméra déjà utilisée"
        CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> "trop de caméras ouvertes"
        CameraDevice.StateCallback.ERROR_CAMERA_DISABLED -> "caméra désactivée"
        CameraDevice.StateCallback.ERROR_CAMERA_DEVICE -> "erreur matérielle"
        CameraDevice.StateCallback.ERROR_CAMERA_SERVICE -> "erreur du service caméra"
        else -> "inconnue"
    }
}
