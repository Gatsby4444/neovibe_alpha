package com.neovibe.neovibe

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
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

        /** Format unifié d'une face de card (9:16). */
        const val CARD_WIDTH = 900
        const val CARD_HEIGHT = 1600
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

    // --- Rendu GPU (chantier : aperçu OpenGL) -----------------------------
    // Isolé du flux de capture réel (écran de test développeur). Voir
    // Camera2Gl.kt et rapports-de-sessions/REPRISE-chantier-gpu-camera.md.
    // Étape 1 : une caméra (camera2Gl). Étape 2 : deux caméras (glBack/glFront)
    // en GPU, rendues chacune sur sa texture, ouvertes en séquence (arrière puis
    // avant, comme le double flux logiciel — évite l'éviction).
    private val glSink: (String, Int, Int, Int) -> Unit = { key, w, h, rot ->
        channel.invokeMethod(
            "previewInfo",
            mapOf("key" to key, "width" to w, "height" to h, "rotation" to rot),
        )
    }
    private val camera2Gl = Camera2Gl(activity, textureRegistry, "gl", glSink)
    private val glBack = Camera2Gl(activity, textureRegistry, "glBack", glSink)
    private val glFront = Camera2Gl(activity, textureRegistry, "glFront", glSink)

    /** Capture audio PARTAGÉE de la vidéo double GPU (un micro → les 2 muxers). */
    private var glAudioEncoder: DualAudioEncoder? = null

    init {
        channel.setMethodCallHandler(this)
    }

    /**
     * Répond AU PLUS UNE fois au canal. Sans ce filet, une seconde réponse
     * (typiquement : le `catch` ci-dessous après qu'un callback caméra a déjà
     * répondu) lève « Reply already submitted » et **tue l'app** — c'est
     * exactement le crash de la capture Oneshot du 2026-07-14.
     */
    private class OnceResult(
        private val delegate: MethodChannel.Result,
        private val method: String,
    ) : MethodChannel.Result {
        private var done = false

        override fun success(value: Any?) {
            if (done) return CamLog.e("canal", "réponse ignorée (déjà répondu) : $method")
            done = true
            delegate.success(value)
        }

        override fun error(code: String, message: String?, details: Any?) {
            if (done) return CamLog.e("canal", "erreur ignorée (déjà répondu) : $method — $message")
            done = true
            delegate.error(code, message, details)
        }

        override fun notImplemented() {
            if (done) return
            done = true
            delegate.notImplemented()
        }
    }

    override fun onMethodCall(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = OnceResult(rawResult, call.method)
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
                    val audio = call.argument<Boolean>("audio") ?: false
                    // On ATTEND que le double flux ait rendu le matériel : rouvrir
                    // CameraX trop tôt laissait le service caméra en vrac
                    // (« Available cameras: 0 », puis « unknown device »).
                    camera2Dual.close {
                        CamLog.i("simple", "ouverture flux simple (arrière=$lensBack)")
                        try {
                            openSingle(p, audio)
                            result.success(mapOf("textureId" to entry!!.id()))
                        } catch (e: Exception) {
                            CamLog.e("simple", "ouverture impossible", e)
                            result.error("CAMERA_ERROR", e.message, null)
                        }
                    }
                }
                "switchLens" -> withProvider(result) { p ->
                    // La pile CameraX peut être libérée (ouverture du double flux
                    // en cours) : basculer ferait un NullPointerException sur les
                    // use cases (vu dans le journal de Jay, v0.9.1 — Jay a tapé la
                    // bascule pendant que le double live s'ouvrait).
                    if (preview == null || imageCapture == null || videoCapture == null) {
                        CamLog.e("simple", "bascule ignorée : flux simple non ouvert")
                        result.error("NOT_OPEN", "Caméra non ouverte", null)
                    } else {
                        lensBack = !lensBack
                        CamLog.i("simple", "bascule caméra → arrière=$lensBack")
                        rebindSingle(p)
                        result.success(mapOf("back" to lensBack))
                    }
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
                // --- Étape 1 du rendu GPU (écran de test dev, isolé) --------
                "openGlPreview" -> withProvider(result) { p ->
                    val back = call.argument<Boolean>("back") ?: true
                    val rotation = call.argument<Int>("rotation") ?: 90
                    val mirror = call.argument<Boolean>("mirror") ?: false
                    CamLog.i("gl", "libération de CameraX avant l'aperçu GPU")
                    p.unbindAll()
                    releaseSingle()
                    // Une seule pile caméra à la fois : on ferme aussi le double
                    // flux logiciel s'il traînait, puis on ouvre le moteur GPU.
                    camera2Dual.close { camera2Gl.open(back, rotation, mirror, result) }
                }
                "closeGlPreview" -> camera2Gl.close { result.success(null) }
                // --- Étape 2 du rendu GPU : les DEUX caméras en OpenGL --------
                "openGlDual" -> withProvider(result) { p ->
                    CamLog.i("gl", "libération de CameraX avant le double flux GPU")
                    p.unbindAll()
                    releaseSingle()
                    camera2Dual.close {
                        // Orientation trouvée au test : rotation 0, miroir off
                        // (la matrice de la SurfaceTexture gère déjà le sens).
                        // Ouverture séquentielle : arrière (attend sa 1re image
                        // rendue) PUIS avant → évite l'éviction.
                        glBack.open(true, 0, false) { okBack ->
                            if (!okBack) {
                                result.error("GL_UNSUPPORTED", "arrière GPU : échec", null)
                                return@open
                            }
                            glFront.open(false, 0, false) { okFront ->
                                if (!okFront) {
                                    glBack.close()
                                    result.error("GL_UNSUPPORTED", "avant GPU : échec", null)
                                } else {
                                    CamLog.i("gl", "DOUBLE FLUX GPU vivant (deux caméras rendues)")
                                    result.success(
                                        mapOf(
                                            "backTextureId" to glBack.textureId,
                                            "frontTextureId" to glFront.textureId,
                                        ),
                                    )
                                }
                            }
                        }
                    }
                }
                "captureGlDual" -> {
                    // Photo GPU des DEUX faces : chaque moteur rend sa dernière
                    // image (instantané, aucune action caméra). Hors thread
                    // principal (capturePhoto attend le thread GL).
                    ioExecutor.execute {
                        val started = System.currentTimeMillis()
                        val back = glBack.capturePhoto()
                        val front = glFront.capturePhoto()
                        if (back == null || front == null) {
                            mainExecutor.execute {
                                result.error("GL_CAPTURE_FAILED", "capture GPU impossible", null)
                            }
                        } else {
                            CamLog.i(
                                "gl",
                                "capture GPU des deux faces en " +
                                    "${System.currentTimeMillis() - started} ms",
                            )
                            mainExecutor.execute {
                                result.success(mapOf("back" to back.path, "front" to front.path))
                            }
                        }
                    }
                }
                "closeGlDual" -> {
                    glFront.close()
                    glBack.close { result.success(null) }
                }
                // --- Étape 4 du rendu GPU : vidéo double (un .mp4 par caméra) ---
                "startGlDualVideo" -> {
                    val audio = call.argument<Boolean>("audio") ?: false
                    ioExecutor.execute {
                        val okBack = glBack.startRecording(audio)
                        val okFront = if (okBack) glFront.startRecording(audio) else false
                        if (!okBack || !okFront) {
                            // Repli propre : on coupe ce qui a démarré.
                            glBack.stopRecording()
                            glFront.stopRecording()
                            mainExecutor.execute {
                                result.error(
                                    "GL_VIDEO_FAILED",
                                    "Double encodeur vidéo refusé par le matériel",
                                    null,
                                )
                            }
                        } else {
                            // Audio partagé : une capture → les DEUX muxers. Si
                            // elle échoue, on continue en vidéo muette (les
                            // caméras cessent d'attendre la piste audio).
                            if (audio) {
                                val enc = DualAudioEncoder(listOf(glBack, glFront))
                                if (enc.start()) {
                                    glAudioEncoder = enc
                                } else {
                                    CamLog.e("gl", "audio indisponible → vidéo double muette")
                                    glBack.disableAudio()
                                    glFront.disableAudio()
                                }
                            }
                            CamLog.i(
                                "gl",
                                "VIDÉO DOUBLE GPU démarrée (deux encodeurs H264" +
                                    "${if (glAudioEncoder != null) " + audio partagé" else ""})",
                            )
                            mainExecutor.execute { result.success(null) }
                        }
                    }
                }
                "stopGlDualVideo" -> {
                    ioExecutor.execute {
                        // Arrêter l'audio EN PREMIER : il pousse ses derniers
                        // paquets (EOS) dans les deux muxers, qui démarrent alors
                        // si besoin, AVANT qu'on arrête les pistes vidéo.
                        glAudioEncoder?.stop()
                        glAudioEncoder = null
                        val back = glBack.stopRecording()
                        val front = glFront.stopRecording()
                        if (back == null || front == null) {
                            mainExecutor.execute {
                                result.error("GL_VIDEO_FAILED", "Arrêt vidéo double impossible", null)
                            }
                        } else {
                            CamLog.i(
                                "gl",
                                "vidéo double GPU : arrière ${back.length() / 1024} Ko, " +
                                    "avant ${front.length() / 1024} Ko",
                            )
                            mainExecutor.execute {
                                result.success(mapOf("back" to back.path, "front" to front.path))
                            }
                        }
                    }
                }
                "startDualVideo" ->
                    // Vidéo double simultanée : non couverte par le moteur
                    // Camera2 dual (deux encodeurs + limite de flux). Le Dart
                    // retombe en photo seule pour le Oneshot.
                    result.error("DUAL_VIDEO_UNSUPPORTED", "Vidéo double non gérée", null)
                "stopDualVideo" ->
                    result.error("NOT_RECORDING", "Aucun enregistrement double", null)
                "normalize" -> {
                    // Recadrage 9:16 + mise au format des cards, EN NATIF.
                    // Le faisait en Dart : décodage + PictureRecorder + encodage
                    // PNG 900×1600 par face → plusieurs secondes pour un Oneshot
                    // (les deux faces). Ici : un décodage sous-échantillonné et
                    // un encodage JPEG, sur un thread de fond.
                    val src = call.argument<String>("path")
                        ?: return result.error("BAD_ARGS", "chemin manquant", null)
                    ioExecutor.execute {
                        val started = System.currentTimeMillis()
                        try {
                            val out = normalize916(src)
                            CamLog.i(
                                "image",
                                "normalisation en ${System.currentTimeMillis() - started} ms " +
                                    "(${out.length() / 1024} Ko)",
                            )
                            mainExecutor.execute {
                                result.success(mapOf("path" to out.path))
                            }
                        } catch (e: Exception) {
                            CamLog.e("image", "normalisation impossible", e)
                            mainExecutor.execute {
                                result.error("NORMALIZE_FAILED", e.message, null)
                            }
                        }
                    }
                }
                "isCameraServiceAlive" -> {
                    // Le service caméra peut être tombé (cameraIdList vide) :
                    // le Dart doit pouvoir le savoir sans provoquer d'erreur.
                    val alive = try {
                        val cm = activity.getSystemService(Context.CAMERA_SERVICE)
                            as android.hardware.camera2.CameraManager
                        cm.cameraIdList.isNotEmpty()
                    } catch (e: Exception) {
                        CamLog.e("camera", "service caméra injoignable", e)
                        false
                    }
                    result.success(alive)
                }
                "probeDual" -> closeAll {
                    // Sonde Camera2 brute : ouvre les DEUX caméras de force,
                    // sans passer par la déclaration d'Android (demande de
                    // Jay : « existe-t-il un moyen de contourner l'API ? »).
                    DualCameraProbe(activity).run { report -> result.success(report) }
                }
                "close" -> {
                    provider?.unbindAll()
                    releaseSingle()
                    // La réponse n'arrive qu'une fois le matériel RENDU : le Dart
                    // peut alors rouvrir sans risque.
                    camera2Dual.close { result.success(null) }
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

    /** Appelé UNIQUEMENT après `camera2Dual.close { … }` (matériel rendu). */
    private fun openSingle(p: ProcessCameraProvider, audio: Boolean) {
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

    private fun closeAll(onDone: (() -> Unit)? = null) {
        provider?.unbindAll()
        releaseSingle()
        camera2Dual.close(onDone)
    }

    /**
     * Image quelconque → **face de card prête** : rotation EXIF appliquée,
     * recadrage 9:16 centré (exactement le cadre montré à l'aperçu — WYSIWYG),
     * mise à l'échelle au format unifié 900×1600, encodage JPEG.
     *
     * Tout en un seul décodage sous-échantillonné. Remplace le pipeline Dart
     * (décodage + `PictureRecorder` + encodage **PNG** 900×1600 par face), qui
     * faisait durer une capture Oneshot plusieurs secondes — assez longtemps
     * pour que Jay change de mode pendant le traitement.
     */
    private fun normalize916(sourcePath: String): File {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(sourcePath, bounds)

        // On ne décode pas 12 Mpx pour en sortir 900×1600 : on divise tant que
        // l'image reste plus grande que la cible.
        var sample = 1
        while (
            bounds.outWidth / (sample * 2) >= CARD_WIDTH &&
            bounds.outHeight / (sample * 2) >= CARD_HEIGHT
        ) {
            sample *= 2
        }
        var bitmap = BitmapFactory.decodeFile(
            sourcePath,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: throw IllegalStateException("image illisible : $sourcePath")

        // Rotation EXIF (posée par le double flux, ou venant de la galerie).
        val degrees = when (
            ExifInterface(sourcePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        ) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (degrees != 0f) {
            val rotated = Bitmap.createBitmap(
                bitmap, 0, 0, bitmap.width, bitmap.height,
                Matrix().apply { postRotate(degrees) }, true,
            )
            if (rotated != bitmap) bitmap.recycle()
            bitmap = rotated
        }

        // Recadrage centré au ratio de la card, puis mise à l'échelle.
        val ratio = CARD_WIDTH.toFloat() / CARD_HEIGHT
        var cropW = bitmap.width.toFloat()
        var cropH = bitmap.height.toFloat()
        if (cropW / cropH > ratio) cropW = cropH * ratio else cropH = cropW / ratio
        val src = Rect(
            ((bitmap.width - cropW) / 2).toInt(),
            ((bitmap.height - cropH) / 2).toInt(),
            ((bitmap.width + cropW) / 2).toInt(),
            ((bitmap.height + cropH) / 2).toInt(),
        )

        val card = Bitmap.createBitmap(CARD_WIDTH, CARD_HEIGHT, Bitmap.Config.ARGB_8888)
        Canvas(card).drawBitmap(
            bitmap,
            src,
            Rect(0, 0, CARD_WIDTH, CARD_HEIGHT),
            Paint(Paint.FILTER_BITMAP_FLAG),
        )
        bitmap.recycle()

        val file = File.createTempFile("nv_face_", ".jpg", activity.cacheDir)
        FileOutputStream(file).use { card.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        card.recycle()
        return file
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
