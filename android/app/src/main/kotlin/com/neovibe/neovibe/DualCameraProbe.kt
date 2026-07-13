package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sonde « double flux » en Camera2 BRUT — contourne la déclaration d'Android.
 *
 * CameraX refuse d'ouvrir deux caméras si `getConcurrentCameraIds()` ne les
 * déclare pas. Beaucoup d'appareils acceptent pourtant en pratique ce qu'ils
 * ne déclarent pas. Cette sonde **ouvre les deux caméras de force** et mesure
 * ce qui se passe RÉELLEMENT :
 *
 *  - la caméra arrière reçoit-elle encore des images APRÈS l'ouverture de la
 *    frontale (ou se fait-elle évincer par le service caméra — c'était le gel
 *    silencieux de la v0.5.0) ;
 *  - la frontale produit-elle des images en même temps.
 *
 * Si les deux comptent des images en parallèle : le double flux est possible
 * sur cet appareil malgré la déclaration, et on peut construire le vrai
 * pipeline Camera2. Sinon, le matériel refuse pour de bon.
 */
@SuppressLint("MissingPermission") // permission caméra déjà accordée
class DualCameraProbe(private val activity: Activity) {

    private val manager =
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /** Résultat brut, lisible dans le HUD développeur. */
    fun run(onResult: (Map<String, Any?>) -> Unit) {
        val thread = HandlerThread("nv-probe").apply { start() }
        val handler = Handler(thread.looper)

        val backId = firstCamera(CameraCharacteristics.LENS_FACING_BACK)
        val frontId = firstCamera(CameraCharacteristics.LENS_FACING_FRONT)
        if (backId == null || frontId == null) {
            onResult(mapOf("error" to "Caméra avant ou arrière introuvable"))
            thread.quitSafely()
            return
        }

        val backFrames = AtomicInteger(0)
        val frontFrames = AtomicInteger(0)
        val backEvicted = AtomicBoolean(false)
        val errors = mutableListOf<String>()
        val opened = mutableListOf<CameraDevice>()
        val textures = mutableListOf<SurfaceTexture>()

        fun cleanup() {
            opened.forEach { runCatching { it.close() } }
            textures.forEach { runCatching { it.release() } }
            thread.quitSafely()
        }

        fun openStream(
            id: String,
            counter: AtomicInteger,
            onDisconnected: () -> Unit,
            onReady: () -> Unit,
        ) {
            manager.openCamera(
                id,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        opened.add(device)
                        val texture = SurfaceTexture(false).apply {
                            setDefaultBufferSize(640, 480)
                        }
                        textures.add(texture)
                        val surface = Surface(texture)
                        val request =
                            device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                .apply { addTarget(surface) }
                        @Suppress("DEPRECATION")
                        device.createCaptureSession(
                            listOf(surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    runCatching {
                                        session.setRepeatingRequest(
                                            request.build(),
                                            object : CameraCaptureSession.CaptureCallback() {
                                                override fun onCaptureCompleted(
                                                    s: CameraCaptureSession,
                                                    r: CaptureRequest,
                                                    result: TotalCaptureResult,
                                                ) {
                                                    counter.incrementAndGet()
                                                }
                                            },
                                            handler,
                                        )
                                    }.onFailure { errors.add("$id: ${it.message}") }
                                    onReady()
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    errors.add("$id: session refusée")
                                    onReady()
                                }
                            },
                            handler,
                        )
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        // ÉVICTION : le service caméra a coupé ce flux pour
                        // laisser la place à l'autre → pas de double flux.
                        errors.add("$id: évincée (onDisconnected)")
                        onDisconnected()
                        runCatching { device.close() }
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        errors.add("$id: erreur $error")
                        onDisconnected()
                        runCatching { device.close() }
                    }
                },
                handler,
            )
        }

        // 1) Arrière seule, 1 s → on vérifie qu'elle produit des images.
        openStream(backId, backFrames, { backEvicted.set(true) }) {
            handler.postDelayed({
                val backAlone = backFrames.get()

                // 2) Ouverture FORCÉE de la frontale, sans rien demander à
                //    getConcurrentCameraIds() : c'est le contournement.
                openStream(frontId, frontFrames, {}) {
                    handler.postDelayed({
                        val backAfter = backFrames.get() - backAlone
                        val front = frontFrames.get()
                        // Verdict : les DEUX doivent continuer à produire.
                        val works = !backEvicted.get() && backAfter > 3 && front > 3
                        activity.runOnUiThread {
                            onResult(
                                mapOf(
                                    "works" to works,
                                    "backAlone" to backAlone,
                                    "backAfterFront" to backAfter,
                                    "frontFrames" to front,
                                    "backEvicted" to backEvicted.get(),
                                    "errors" to errors.joinToString(" | "),
                                ),
                            )
                        }
                        cleanup()
                    }, 1500)
                }
            }, 1000)
        }
    }

    private fun firstCamera(facing: Int): String? = manager.cameraIdList.firstOrNull {
        manager.getCameraCharacteristics(it)
            .get(CameraCharacteristics.LENS_FACING) == facing
    }
}
