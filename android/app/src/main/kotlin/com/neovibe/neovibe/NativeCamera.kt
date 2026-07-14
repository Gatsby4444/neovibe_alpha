package com.neovibe.neovibe

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.view.Surface
import android.view.WindowManager
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.PendingRecording
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Couche caméra native NeoVibe (CameraX) — remplace le plugin `camera`
 * (décision Jay 2026-07-13, remplacement complet) pour débloquer :
 *  1. le double flux simultané du Oneshot (préview + photo + vidéo des deux
 *     caméras en même temps, si le matériel le permet) ;
 *  2. la bascule avant/arrière PENDANT une vidéo (Mono, comme Snapchat),
 *     via l'enregistrement persistant de CameraX ;
 *  3. FLAG_SECURE (anti-capture), désactivable en mode développeur.
 *
 * Tous les échecs matériels remontent en erreurs typées : le Dart décide
 * des replis (vue simple, photo seulement…).
 */
class NativeCamera(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        /** Débit vidéo plafonné — voir recorder() (limite d'upload Supabase). */
        const val VIDEO_BITRATE = 3_500_000
    }

    private val channel = MethodChannel(messenger, "neovibe/camera")
    private val mainExecutor: Executor = ContextCompat.getMainExecutor(activity)
    private val ioExecutor = Executors.newSingleThreadExecutor()

    /** Dernière raison d'échec du double flux (diagnostic, HUD développeur). */
    private var lastDualError: String? = null

    private var provider: ProcessCameraProvider? = null

    // --- Mode simple -----------------------------------------------------
    // SurfaceProducer (et NON SurfaceTextureEntry) : c'est l'API que le
    // plugin caméra officiel utilise depuis Flutter 3.22 — la variante
    // SurfaceTexture laisse Flutter appliquer une matrice de transformation
    // périmée, ce qui étire et fait pivoter l'aperçu (bug remonté par Jay
    // sur la v0.7.0). SurfaceProducer.setSize règle le buffer proprement.
    private var entry: TextureRegistry.SurfaceProducer? = null
    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var stopResult: MethodChannel.Result? = null
    private var videoPath: String? = null
    private var lensBack = true

    // --- Mode double (Oneshot) -------------------------------------------
    // Piloté en Camera2 BRUT (pas CameraX) : le matériel accepte deux flux
    // que la déclaration concurrente d'Android nie (prouvé par la sonde).
    private val camera2Dual = Camera2Dual(activity, textureRegistry) { key, w, h, rot ->
        channel.invokeMethod(
            "previewInfo",
            mapOf("key" to key, "width" to w, "height" to h, "rotation" to rot),
        )
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // --- Journal (diagnostic, Réglages → Développeur) ----------
                "readLog" -> result.success(CamLog.read())
                "clearLog" -> {
                    CamLog.clear()
                    result.success(null)
                }
                // Le Dart écrit dans le MÊME journal que le natif : une seule
                // trace à copier, dans l'ordre chronologique.
                "log" -> {
                    CamLog.i("dart", call.argument<String>("message") ?: "")
                    result.success(null)
                }
                "capabilities" -> withProvider(result) { p ->
                    // Diagnostic complet : ce que CameraX annonce, ce que le
                    // pilote Camera2 annonce (source de vérité du matériel),
                    // et l'appareil — pour trancher un « mon tel en est
                    // capable » sur des faits (demande de Jay).
                    val camera2Ids = try {
                        if (android.os.Build.VERSION.SDK_INT >= 30) {
                            val manager = activity.getSystemService(Context.CAMERA_SERVICE)
                                as android.hardware.camera2.CameraManager
                            manager.concurrentCameraIds.size
                        } else {
                            -1 // API < 30 : l'API publique n'existe pas
                        }
                    } catch (e: Exception) {
                        -2
                    }
                    result.success(
                        mapOf(
                            "concurrent" to p.availableConcurrentCameraInfos.isNotEmpty(),
                            "cameraXCombos" to p.availableConcurrentCameraInfos.size,
                            "camera2Combos" to camera2Ids,
                            "device" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                            "lastDualError" to (camera2Dual.lastReport ?: lastDualError),
                        ),
                    )
                }
                "open" -> withProvider(result) { p ->
                    lensBack = call.argument<Boolean>("back") ?: true
                    CamLog.i("simple", "ouverture flux simple (arrière=$lensBack)")
                    openSingle(p, call.argument<Boolean>("audio") ?: false)
                    result.success(mapOf("textureId" to entry!!.id()))
                }
                "switchLens" -> withProvider(result) { p ->
                    lensBack = !lensBack
                    CamLog.i("simple", "bascule caméra → arrière=$lensBack")
                    rebindSingle(p)
                    result.success(mapOf("back" to lensBack))
                }
                "takePicture" -> takePicture(result)
                "startVideo" -> startVideo(call, result)
                "stopVideo" -> stopVideo(result)
                "openDual" -> withProvider(result) { p ->
                    // On libère CameraX (une seule pile caméra à la fois) puis
                    // on ouvre le duo en Camera2 brut.
                    CamLog.i("dual", "libération de CameraX avant le double flux")
                    p.unbindAll()
                    releaseSingle()
                    camera2Dual.open(result)
                }
                "takeDualPictures" -> camera2Dual.capture(result)
                "startDualVideo" ->
                    // Vidéo double simultanée : non couverte par le moteur
                    // Camera2 dual (deux encodeurs + limite de flux). Le Dart
                    // retombe en photo seule pour le Oneshot.
                    result.error("DUAL_VIDEO_UNSUPPORTED", "Vidéo double non gérée", null)
                "stopDualVideo" ->
                    result.error("NOT_RECORDING", "Aucun enregistrement double", null)
                "probeDual" -> {
                    // Sonde Camera2 brute : ouvre les DEUX caméras de force,
                    // sans passer par la déclaration d'Android (demande de
                    // Jay : « existe-t-il un moyen de contourner l'API ? »).
                    closeAll()
                    DualCameraProbe(activity).run { report -> result.success(report) }
                }
                "close" -> {
                    closeAll()
                    result.success(null)
                }
                "setSecure" -> {
                    val on = call.argument<Boolean>("on") ?: true
                    activity.runOnUiThread {
                        if (on) {
                            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            CamLog.e("camera", "échec de « ${call.method} »", e)
            result.error("CAMERA_ERROR", e.message, null)
        }
    }

    /** Obtient le ProcessCameraProvider (async) puis exécute [block]. */
    private fun withProvider(
        result: MethodChannel.Result,
        block: (ProcessCameraProvider) -> Unit,
    ) {
        val cached = provider
        if (cached != null) {
            block(cached)
            return
        }
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            try {
                provider = future.get()
                block(provider!!)
            } catch (e: Exception) {
                result.error("CAMERA_ERROR", e.message, null)
            }
        }, mainExecutor)
    }

    private fun selector(back: Boolean): CameraSelector =
        if (back) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA

    /**
     * 720p à débit PLAFONNÉ (~3,5 Mbit/s). Au débit par défaut de CameraX
     * (≈12 Mbit/s), une vidéo dépassait les 50 Mo autorisés par Supabase dès
     * ~35 s → StorageException 413 (bug remonté par Jay sur une vidéo Mono).
     * Avec ce plafond, la limite de 61 s tient dans ~28 Mo.
     */
    private fun recorder(): Recorder = Recorder.Builder()
        .setQualitySelector(
            QualitySelector.from(
                Quality.HD,
                FallbackStrategy.higherQualityOrLowerThan(Quality.HD),
            ),
        )
        .setTargetVideoEncodingBitRate(VIDEO_BITRATE)
        .build()

    /**
     * SurfaceProvider branché sur une texture Flutter. À chaque bind CameraX
     * envoie une nouvelle SurfaceRequest : on fournit une Surface issue de la
     * MÊME SurfaceTexture (l'id côté Flutter ne change pas) et on notifie le
     * Dart de la taille + rotation à appliquer à l'affichage.
     */
    private fun surfaceProvider(
        producer: TextureRegistry.SurfaceProducer,
        key: String,
    ): Preview.SurfaceProvider = Preview.SurfaceProvider { request ->
        // setSize AVANT getSurface : Flutter dimensionne la texture sur le
        // buffer réel de la caméra (plus d'étirement).
        producer.setSize(request.resolution.width, request.resolution.height)
        val surface = producer.surface
        // La Surface appartient au producer : ne pas la libérer ici, sinon
        // l'aperçu meurt au premier rebind (bascule de caméra).
        request.provideSurface(surface, mainExecutor) { }
        request.setTransformationInfoListener(mainExecutor) { info ->
            channel.invokeMethod(
                "previewInfo",
                mapOf(
                    "key" to key,
                    "width" to request.resolution.width,
                    "height" to request.resolution.height,
                    "rotation" to info.rotationDegrees,
                ),
            )
        }
    }

    // ------------------------------------------------------------------
    // Mode simple (tous les modes sauf Oneshot double)
    // ------------------------------------------------------------------

    private fun openSingle(p: ProcessCameraProvider, audio: Boolean) {
        // On revient d'un éventuel double flux Camera2 : le fermer.
        camera2Dual.close()
        entry = entry ?: textureRegistry.createSurfaceProducer()
        preview = Preview.Builder().build().also {
            it.setSurfaceProvider(surfaceProvider(entry!!, "main"))
        }
        imageCapture = ImageCapture.Builder()
            .setTargetRotation(Surface.ROTATION_0)
            .build()
        videoCapture = VideoCapture.withOutput(recorder()).also {
            it.targetRotation = Surface.ROTATION_0
        }
        bindSingle(p)
    }

    private fun bindSingle(p: ProcessCameraProvider) {
        p.unbindAll()
        p.bindToLifecycle(
            activity as LifecycleOwner,
            selector(lensBack),
            preview!!,
            imageCapture!!,
            videoCapture!!,
        )
    }

    /**
     * Rebind sur l'autre caméra. Pendant un enregistrement PERSISTANT, la
     * vidéo continue à travers le rebind : c'est la bascule en cours de
     * vidéo façon Snapchat (Mono).
     */
    private fun rebindSingle(p: ProcessCameraProvider) {
        bindSingle(p)
    }

    private fun takePicture(result: MethodChannel.Result) {
        val capture = imageCapture
            ?: return result.error("NOT_OPEN", "Caméra non ouverte", null)
        val file = File.createTempFile("nv_shot_", ".jpg", activity.cacheDir)
        capture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            ioExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    bakeRotation(file.path)
                    mainExecutor.execute { result.success(mapOf("path" to file.path)) }
                }

                override fun onError(e: ImageCaptureException) {
                    mainExecutor.execute { result.error("CAPTURE_FAILED", e.message, null) }
                }
            },
        )
    }

    @androidx.annotation.OptIn(androidx.camera.video.ExperimentalPersistentRecording::class)
    private fun startVideo(call: MethodCall, result: MethodChannel.Result) {
        val capture = videoCapture
            ?: return result.error("NOT_OPEN", "Caméra non ouverte", null)
        val audio = call.argument<Boolean>("audio") ?: false
        val file = File.createTempFile("nv_video_", ".mp4", activity.cacheDir)
        videoPath = file.path
        var pending: PendingRecording = capture.output
            .prepareRecording(activity, FileOutputOptions.Builder(file).build())
            // Persistant : l'enregistrement SURVIT au rebind des use cases,
            // donc à la bascule avant/arrière (chantier caméra, consigne Jay).
            .asPersistentRecording()
        if (audio) {
            try {
                pending = pending.withAudioEnabled()
            } catch (_: SecurityException) {
                // Micro refusé : vidéo muette, non bloquant (consigne Jay).
            }
        }
        recording = pending.start(mainExecutor) { event ->
            if (event is VideoRecordEvent.Finalize) {
                val res = stopResult
                stopResult = null
                if (event.hasError()) {
                    res?.error("VIDEO_FAILED", "Erreur vidéo ${event.error}", null)
                } else {
                    res?.success(mapOf("path" to videoPath))
                }
            }
        }
        result.success(null)
    }

    private fun stopVideo(result: MethodChannel.Result) {
        val active = recording
            ?: return result.error("NOT_RECORDING", "Aucun enregistrement", null)
        stopResult = result
        recording = null
        active.stop()
    }


    // ------------------------------------------------------------------

    /** Libère la pile CameraX simple (avant un passage au double flux). */
    private fun releaseSingle() {
        recording?.stop()
        recording = null
        entry?.release()
        entry = null
        preview = null
        imageCapture = null
        videoCapture = null
    }

    private fun closeAll() {
        camera2Dual.close()
        provider?.unbindAll()
        releaseSingle()
    }

    /**
     * Applique la rotation EXIF dans les pixels (et la retire des métadonnées)
     * en sous-échantillonnant : le pipeline Dart (recadrage 900×1600) lit
     * alors l'image déjà droite, quel que soit le décodeur.
     */
    private fun bakeRotation(path: String) {
        try {
            val exif = ExifInterface(path)
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
            val degrees = when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
            if (degrees == 0f) return
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 1800) sample *= 2
            val bitmap = BitmapFactory.decodeFile(
                path,
                BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: return
            val matrix = Matrix().apply { postRotate(degrees) }
            val rotated = Bitmap.createBitmap(
                bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true,
            )
            FileOutputStream(path).use {
                rotated.compress(Bitmap.CompressFormat.JPEG, 92, it)
            }
            if (rotated != bitmap) bitmap.recycle()
            rotated.recycle()
        } catch (_: Exception) {
            // Rotation non appliquée : l'image reste lisible (EXIF intact).
        }
    }
}
