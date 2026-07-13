package com.neovibe.neovibe

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ConcurrentCamera
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

        /** Concurrent camera : Android impose ≤ 720p par flux. */
        val CONCURRENT_SIZE = Size(1280, 720)
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
    private var dualBackEntry: TextureRegistry.SurfaceProducer? = null
    private var dualFrontEntry: TextureRegistry.SurfaceProducer? = null
    private var dualBackImage: ImageCapture? = null
    private var dualFrontImage: ImageCapture? = null
    private var dualBackVideo: VideoCapture<Recorder>? = null
    private var dualFrontVideo: VideoCapture<Recorder>? = null
    private var dualBackRecording: Recording? = null
    private var dualFrontRecording: Recording? = null
    private var dualStopResult: MethodChannel.Result? = null
    private var dualBackPath: String? = null
    private var dualFrontPath: String? = null
    private var dualFinalized = 0

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
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
                            "lastDualError" to lastDualError,
                        ),
                    )
                }
                "open" -> withProvider(result) { p ->
                    lensBack = call.argument<Boolean>("back") ?: true
                    openSingle(p, call.argument<Boolean>("audio") ?: false)
                    result.success(mapOf("textureId" to entry!!.id()))
                }
                "switchLens" -> withProvider(result) { p ->
                    lensBack = !lensBack
                    rebindSingle(p)
                    result.success(mapOf("back" to lensBack))
                }
                "takePicture" -> takePicture(result)
                "startVideo" -> startVideo(call, result)
                "stopVideo" -> stopVideo(result)
                "openDual" -> withProvider(result) { p -> openDual(p, result) }
                "takeDualPictures" -> takeDualPictures(result)
                "startDualVideo" -> startDualVideo(call, result)
                "stopDualVideo" -> stopDualVideo(result)
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
        closeDual(p)
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
    // Mode double simultané (Oneshot)
    // ------------------------------------------------------------------

    /**
     * On TENTE toujours le bind concurrent, même si `availableConcurrentCameraInfos`
     * est vide : cette liste est un faux négatif fréquent (des appareils
     * capables la renvoient vide). Seul l'échec réel du bind fait basculer
     * en vue simple — sinon on privait Jay du double flux sans raison.
     */
    private fun openDual(p: ProcessCameraProvider, result: MethodChannel.Result) {
        try {
            p.unbindAll()
            recording = null
            dualBackEntry = dualBackEntry ?: textureRegistry.createSurfaceProducer()
            dualFrontEntry = dualFrontEntry ?: textureRegistry.createSurfaceProducer()
            // En mode concurrent, Android impose une résolution ≤ 720p par
            // flux : sans cette contrainte, CameraX demande du 1080p+ et le
            // bind ÉCHOUE sur des appareils pourtant capables (piste n°1 du
            // « mon tel en est capable » de Jay).
            val backPreview = Preview.Builder()
                .setResolutionSelector(concurrentResolution())
                .build().also {
                    it.setSurfaceProvider(surfaceProvider(dualBackEntry!!, "dualBack"))
                }
            val frontPreview = Preview.Builder()
                .setResolutionSelector(concurrentResolution())
                .build().also {
                    it.setSurfaceProvider(surfaceProvider(dualFrontEntry!!, "dualFront"))
                }
            dualBackImage = ImageCapture.Builder()
                .setTargetRotation(Surface.ROTATION_0)
                .setResolutionSelector(concurrentResolution())
                .build()
            dualFrontImage = ImageCapture.Builder()
                .setTargetRotation(Surface.ROTATION_0)
                .setResolutionSelector(concurrentResolution())
                .build()
            val configs = listOf(
                ConcurrentCamera.SingleCameraConfig(
                    selector(true),
                    UseCaseGroup.Builder()
                        .addUseCase(backPreview)
                        .addUseCase(dualBackImage!!)
                        .build(),
                    activity as LifecycleOwner,
                ),
                ConcurrentCamera.SingleCameraConfig(
                    selector(false),
                    UseCaseGroup.Builder()
                        .addUseCase(frontPreview)
                        .addUseCase(dualFrontImage!!)
                        .build(),
                    activity as LifecycleOwner,
                ),
            )
            p.bindToLifecycle(configs)
            result.success(
                mapOf(
                    "backTextureId" to dualBackEntry!!.id(),
                    "frontTextureId" to dualFrontEntry!!.id(),
                ),
            )
        } catch (e: Exception) {
            closeDual(p)
            // La raison exacte remonte au Dart (affichée dans le HUD dev) :
            // « non supporté » n'apprend rien, le message de CameraX si.
            lastDualError = "${e.javaClass.simpleName}: ${e.message}"
            result.error("DUAL_UNSUPPORTED", lastDualError, null)
        }
    }

    private fun concurrentResolution() = ResolutionSelector.Builder()
        .setResolutionStrategy(
            ResolutionStrategy(
                CONCURRENT_SIZE,
                ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
            ),
        )
        .build()

    private fun takeDualPictures(result: MethodChannel.Result) {
        val backCapture = dualBackImage
        val frontCapture = dualFrontImage
        if (backCapture == null || frontCapture == null) {
            result.error("NOT_OPEN", "Double flux non ouvert", null)
            return
        }
        val backFile = File.createTempFile("nv_back_", ".jpg", activity.cacheDir)
        val frontFile = File.createTempFile("nv_front_", ".jpg", activity.cacheDir)
        var done = 0
        var failed = false
        fun complete() {
            done++
            if (done == 2 && !failed) {
                mainExecutor.execute {
                    result.success(
                        mapOf("back" to backFile.path, "front" to frontFile.path),
                    )
                }
            }
        }
        fun fail(e: Exception) {
            if (!failed) {
                failed = true
                mainExecutor.execute { result.error("CAPTURE_FAILED", e.message, null) }
            }
        }
        backCapture.takePicture(
            ImageCapture.OutputFileOptions.Builder(backFile).build(),
            ioExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    bakeRotation(backFile.path)
                    complete()
                }

                override fun onError(e: ImageCaptureException) = fail(e)
            },
        )
        frontCapture.takePicture(
            ImageCapture.OutputFileOptions.Builder(frontFile).build(),
            ioExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    bakeRotation(frontFile.path)
                    complete()
                }

                override fun onError(e: ImageCaptureException) = fail(e)
            },
        )
    }

    /**
     * Vidéo double simultanée (Oneshot vidéo, priorité 1 de Jay) : rebind
     * concurrent avec Preview+VideoCapture par caméra, deux fichiers. Le son
     * n'est pris QUE sur la caméra arrière (un seul micro). Échec de bind →
     * DUAL_VIDEO_UNSUPPORTED, le Dart repasse en photo seule.
     */
    @androidx.annotation.OptIn(androidx.camera.video.ExperimentalPersistentRecording::class)
    private fun startDualVideo(call: MethodCall, result: MethodChannel.Result) {
        val p = provider ?: return result.error("NOT_OPEN", "Caméra non ouverte", null)
        if (dualBackEntry == null || dualFrontEntry == null) {
            result.error("NOT_OPEN", "Double flux non ouvert", null)
            return
        }
        val audio = call.argument<Boolean>("audio") ?: false
        try {
            p.unbindAll()
            val backPreview = Preview.Builder()
                .setResolutionSelector(concurrentResolution())
                .build().also {
                    it.setSurfaceProvider(surfaceProvider(dualBackEntry!!, "dualBack"))
                }
            val frontPreview = Preview.Builder()
                .setResolutionSelector(concurrentResolution())
                .build().also {
                    it.setSurfaceProvider(surfaceProvider(dualFrontEntry!!, "dualFront"))
                }
            dualBackVideo = VideoCapture.withOutput(recorder()).also {
                it.targetRotation = Surface.ROTATION_0
            }
            dualFrontVideo = VideoCapture.withOutput(recorder()).also {
                it.targetRotation = Surface.ROTATION_0
            }
            val configs = listOf(
                ConcurrentCamera.SingleCameraConfig(
                    selector(true),
                    UseCaseGroup.Builder()
                        .addUseCase(backPreview)
                        .addUseCase(dualBackVideo!!)
                        .build(),
                    activity as LifecycleOwner,
                ),
                ConcurrentCamera.SingleCameraConfig(
                    selector(false),
                    UseCaseGroup.Builder()
                        .addUseCase(frontPreview)
                        .addUseCase(dualFrontVideo!!)
                        .build(),
                    activity as LifecycleOwner,
                ),
            )
            p.bindToLifecycle(configs)

            val backFile = File.createTempFile("nv_back_", ".mp4", activity.cacheDir)
            val frontFile = File.createTempFile("nv_front_", ".mp4", activity.cacheDir)
            dualBackPath = backFile.path
            dualFrontPath = frontFile.path
            dualFinalized = 0
            var backPending = dualBackVideo!!.output
                .prepareRecording(activity, FileOutputOptions.Builder(backFile).build())
            if (audio) {
                try {
                    backPending = backPending.withAudioEnabled()
                } catch (_: SecurityException) {
                }
            }
            dualBackRecording = backPending.start(mainExecutor) { onDualEvent(it) }
            dualFrontRecording = dualFrontVideo!!.output
                .prepareRecording(activity, FileOutputOptions.Builder(frontFile).build())
                .start(mainExecutor) { onDualEvent(it) }
            result.success(null)
        } catch (e: Exception) {
            dualBackRecording?.stop()
            dualFrontRecording?.stop()
            dualBackRecording = null
            dualFrontRecording = null
            result.error("DUAL_VIDEO_UNSUPPORTED", e.message, null)
        }
    }

    private fun onDualEvent(event: VideoRecordEvent) {
        if (event !is VideoRecordEvent.Finalize) return
        dualFinalized++
        if (dualFinalized < 2) return
        val res = dualStopResult
        dualStopResult = null
        if (event.hasError() && res != null) {
            res.error("VIDEO_FAILED", "Erreur vidéo double ${event.error}", null)
        } else {
            res?.success(mapOf("back" to dualBackPath, "front" to dualFrontPath))
        }
    }

    private fun stopDualVideo(result: MethodChannel.Result) {
        val back = dualBackRecording
        val front = dualFrontRecording
        if (back == null && front == null) {
            result.error("NOT_RECORDING", "Aucun enregistrement double", null)
            return
        }
        dualStopResult = result
        dualBackRecording = null
        dualFrontRecording = null
        back?.stop()
        front?.stop()
    }

    // ------------------------------------------------------------------

    private fun closeDual(p: ProcessCameraProvider?) {
        dualBackRecording?.stop()
        dualFrontRecording?.stop()
        dualBackRecording = null
        dualFrontRecording = null
        dualBackImage = null
        dualFrontImage = null
        dualBackVideo = null
        dualFrontVideo = null
    }

    private fun closeAll() {
        recording?.stop()
        recording = null
        closeDual(provider)
        provider?.unbindAll()
        entry?.release()
        entry = null
        dualBackEntry?.release()
        dualBackEntry = null
        dualFrontEntry?.release()
        dualFrontEntry = null
        preview = null
        imageCapture = null
        videoCapture = null
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
