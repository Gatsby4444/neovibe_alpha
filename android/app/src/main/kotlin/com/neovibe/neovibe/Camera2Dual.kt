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
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream

/**
 * Moteur double flux Oneshot en **Camera2 BRUT** — CONTOURNE la déclaration
 * `getConcurrentCameraIds()` d'Android que CameraX respecte (et qui, sur le
 * Redmi Note 10 Pro de Jay, dit « non » alors que le matériel accepte : la
 * sonde `DualCameraProbe` l'a prouvé). On ouvre les deux caméras de force,
 * chacune avec un flux d'aperçu (vers une texture Flutter) + un flux photo
 * (ImageReader JPEG).
 *
 * Aperçu + photo uniquement. La VIDÉO double simultanée est un cran au-dessus
 * (deux encodeurs + limite de flux concurrents du matériel) et reste à part.
 *
 * Si la configuration de session échoue, ou si une caméra est évincée
 * (`onDisconnected` = le service caméra a coupé le premier flux), on remonte
 * l'échec : le Dart repasse alors en vue simple.
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

    /** État d'une caméra du duo. */
    private inner class Cam(val key: String, val back: Boolean) {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var producer: TextureRegistry.SurfaceProducer? = null
        var reader: ImageReader? = null
        var sensorOrientation = 0
        var pendingCapture: ((File?) -> Unit)? = null
    }

    private val previewSize = android.util.Size(1280, 720)

    fun open(result: MethodChannel.Result) {
        thread = HandlerThread("nv-cam2-dual").also { it.start() }
        handler = Handler(thread!!.looper)

        val backId = firstCamera(CameraCharacteristics.LENS_FACING_BACK)
        val frontId = firstCamera(CameraCharacteristics.LENS_FACING_FRONT)
        if (backId == null || frontId == null) {
            fail(result, "Caméra avant ou arrière introuvable")
            return
        }

        var opened = 0
        var failed = false
        fun onOneReady(ok: Boolean) {
            if (failed) return
            if (!ok) {
                failed = true
                closeInternal()
                fail(result, "Session double flux refusée (bind Camera2)")
                return
            }
            opened++
            if (opened == 2) {
                active = true
                result.success(
                    mapOf(
                        "backTextureId" to backTextureId,
                        "frontTextureId" to frontTextureId,
                    ),
                )
            }
        }

        openCam("dualBack", backId, true, ::onOneReady)
        openCam("dualFront", frontId, false, ::onOneReady)
    }

    private fun openCam(
        key: String,
        id: String,
        back: Boolean,
        onReady: (Boolean) -> Unit,
    ) {
        val cam = Cam(key, back)
        cams[key] = cam
        cam.sensorOrientation = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

        val producer = textureRegistry.createSurfaceProducer()
        producer.setSize(previewSize.width, previewSize.height)
        cam.producer = producer
        if (back) backTextureId = producer.id() else frontTextureId = producer.id()

        val reader = ImageReader.newInstance(
            previewSize.width, previewSize.height, ImageFormat.JPEG, 2,
        )
        cam.reader = reader

        // Le capteur est monté « paysage » : en portrait, l'aperçu doit
        // pivoter de sensorOrientation (comme le faisait CameraX).
        previewInfoSink(key, previewSize.width, previewSize.height, cam.sensorOrientation)

        manager.openCamera(
            id,
            object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cam.device = device
                    val previewSurface = producer.surface
                    createSession(cam, previewSurface, reader.surface, onReady)
                }

                override fun onDisconnected(device: CameraDevice) {
                    // Éviction : le matériel a coupé ce flux → pas de double.
                    device.close()
                    onReady(false)
                }

                override fun onError(device: CameraDevice, error: Int) {
                    device.close()
                    onReady(false)
                }
            },
            handler,
        )
    }

    @Suppress("DEPRECATION")
    private fun createSession(
        cam: Cam,
        previewSurface: Surface,
        readerSurface: Surface,
        onReady: (Boolean) -> Unit,
    ) {
        val device = cam.device ?: return onReady(false)
        device.createCaptureSession(
            listOf(previewSurface, readerSurface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    cam.session = session
                    val request = device.createCaptureRequest(
                        CameraDevice.TEMPLATE_PREVIEW,
                    ).apply { addTarget(previewSurface) }
                    runCatching {
                        session.setRepeatingRequest(request.build(), null, handler)
                    }.onFailure { onReady(false); return@onConfigured }
                    onReady(true)
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    onReady(false)
                }
            },
            handler,
        )
    }

    /** Photo simultanée des deux caméras : arrière = recto, avant = verso. */
    fun capture(result: MethodChannel.Result) {
        if (!active) return result.error("NOT_OPEN", "Double flux non ouvert", null)
        val files = HashMap<String, File?>()
        var done = 0
        var failed = false
        fun collect(key: String, file: File?) {
            if (failed) return
            files[key] = file
            if (file == null) {
                failed = true
                activity.runOnUiThread {
                    result.error("CAPTURE_FAILED", "Capture $key échouée", null)
                }
                return
            }
            done++
            if (done == 2) {
                activity.runOnUiThread {
                    result.success(
                        mapOf(
                            "back" to files["dualBack"]?.path,
                            "front" to files["dualFront"]?.path,
                        ),
                    )
                }
            }
        }
        captureOne(cams["dualBack"]) { collect("dualBack", it) }
        captureOne(cams["dualFront"]) { collect("dualFront", it) }
    }

    private fun captureOne(cam: Cam?, onFile: (File?) -> Unit) {
        val device = cam?.device
        val session = cam?.session
        val reader = cam?.reader
        if (device == null || session == null || reader == null) return onFile(null)

        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val buffer = image.planes[0].buffer
                val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
                val file = File.createTempFile("nv_${cam.key}_", ".jpg", activity.cacheDir)
                FileOutputStream(file).use { it.write(bytes) }
                onFile(file)
            } catch (e: Exception) {
                onFile(null)
            } finally {
                image.close()
            }
        }, handler)

        val request = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
            .apply {
                addTarget(reader.surface)
                // Oriente le JPEG à l'endroit (EXIF), comme CameraX en simple.
                val orientation = if (cam.back) {
                    cam.sensorOrientation
                } else {
                    (360 - cam.sensorOrientation) % 360
                }
                set(CaptureRequest.JPEG_ORIENTATION, orientation)
            }
        runCatching {
            session.capture(request.build(), null, handler)
        }.onFailure { onFile(null) }
    }

    fun close() {
        closeInternal()
        active = false
    }

    private fun closeInternal() {
        cams.values.forEach { cam ->
            runCatching { cam.session?.close() }
            runCatching { cam.device?.close() }
            runCatching { cam.reader?.close() }
            runCatching { cam.producer?.release() }
        }
        cams.clear()
        backTextureId = -1
        frontTextureId = -1
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun fail(result: MethodChannel.Result, message: String) {
        thread?.quitSafely()
        thread = null
        activity.runOnUiThread {
            result.error("DUAL_UNSUPPORTED", message, null)
        }
    }

    private fun firstCamera(facing: Int): String? =
        manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.LENS_FACING) == facing
        }
}
