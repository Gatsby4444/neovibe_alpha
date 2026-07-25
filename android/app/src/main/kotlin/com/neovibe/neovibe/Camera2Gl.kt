package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * ÉTAPE 1 du chantier « rendu caméra GPU » — **une seule caméra, rendu OpenGL**.
 *
 * ## Objectif de cette étape
 *
 * Prouver, EN ISOLÉ (écran de test développeur, aucun impact sur le flux de
 * capture réel), que la plomberie **OpenGL ↔ Flutter** fonctionne :
 *
 *   caméra → `SurfaceTexture` (texture externe OES, sortie MATÉRIELLE) → shader
 *   GPU → `EGLWindowSurface` adossée à une texture Flutter (`SurfaceProducer`).
 *
 * C'est le chemin de GoNext (rendu GPU, ~45 i/s), par opposition au rendu
 * logiciel de [Camera2Dual] (`lockCanvas`, ~20-27 i/s + freezes). **Validé sur
 * le Redmi de Jay : ~30 i/s CONSTANT, zéro freeze.**
 *
 * ## Orientation (v0.9.7)
 *
 * La rotation portrait est faite **dans le GPU, sur les COORDONNÉES DE TEXTURE**
 * (pas sur la géométrie — tourner la géométrie dans un cadre non carré
 * distordait, v0.9.5 ; déléguer au Dart ne s'appliquait pas, v0.9.6). Les
 * positions remplissent tout le cadre PORTRAIT (720×1280) et on tourne
 * seulement l'échantillonnage : une rotation de 90° aligne alors 1280 texels
 * sur 1280 px et 720 sur 720 → **aucune distorsion**, image droite. Le miroir
 * de la frontale est aussi fait ici. Côté Dart : rotation 0, `mirror: false`.
 *
 * Thread : tout le GL vit sur [glHandler] avec son contexte EGL. Les API Flutter
 * (création de la texture) restent sur le thread principal.
 */
@SuppressLint("MissingPermission") // permission caméra déjà accordée
class Camera2Gl(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    private val previewKey: String,
    private val previewInfoSink: (key: String, w: Int, h: Int, rot: Int) -> Unit,
) : DualAudioEncoder.AudioSink {
    private val manager =
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var glThread: HandlerThread? = null
    private var glHandler: Handler? = null

    private var camThread: HandlerThread? = null
    private var camHandler: Handler? = null

    // EGL
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    /** Config EGL retenue (réutilisée pour la surface de l'encodeur, étape 4). */
    private var eglConfig: EGLConfig? = null

    // --- Étape 4 : encodeur vidéo (une piste .mp4 par caméra) ---------------
    // Le rendu dessine la même image dans DEUX surfaces EGL : l'aperçu ET la
    // surface d'entrée du MediaCodec (même contexte → texture OES + shader
    // partagés). Toujours 1 flux/caméra ; coût CPU ≈ 0 (le GPU fait le double
    // dessin, le codec matériel encode).
    private var recording = false
    private var encoder: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var encoderEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var videoFile: File? = null
    private val encoderBufferInfo = MediaCodec.BufferInfo()

    /** Origine des PTS vidéo (1re image encodée, horloge du capteur) → la piste
     * vidéo démarre à ~0. */
    private var videoFirstTimestampNs = 0L

    /** LE MÊME instant, sur l'horloge `System.nanoTime` (celle de la capture
     * audio) : origine commune aux deux pistes. L'audio ne démarre pas en même
     * temps que la vidéo (~450 ms plus tard) ; c'est ce décalage réel qu'il
     * faut conserver, et non remettre chaque piste à zéro de son côté. */
    private var videoFirstWallNs = 0L

    // Le muxer est touché par DEUX threads : le thread GL (piste vidéo) et le
    // thread audio (piste audio). MediaMuxer n'est PAS thread-safe → tout accès
    // (addTrack/start/writeSampleData/stop) passe par [muxerLock].
    private val muxerLock = Any()
    private var muxer: MediaMuxer? = null
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1
    private var muxerStarted = false

    /** Cet enregistrement inclut-il l'audio ? (le muxer attend alors la piste
     * audio avant de démarrer). Mis à false si la capture audio échoue. */
    private var hasAudio = false

    // Texture Flutter (sortie affichée)
    private var producer: TextureRegistry.SurfaceProducer? = null
    var textureId: Long = -1
        private set

    // Entrée caméra (texture externe OES + SurfaceTexture)
    private var oesTexId = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null
    private var cameraSurface: Surface? = null

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null

    private var sensorOrientation = 90
    private var mirror = false
    private var fpsRange: Range<Int>? = null

    /** Dimensions de la sortie affichée (PORTRAIT). */
    private var outW = 720
    private var outH = 1280

    // GL program
    private var program = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uMvpLoc = 0
    private var uStMatrixLoc = 0
    private var uTexRotLoc = 0

    private val stMatrix = FloatArray(16)
    private val mvpMatrix = FloatArray(16)

    /** Rotation portrait + miroir, appliquée aux COORDONNÉES DE TEXTURE. */
    private val texRotMatrix = FloatArray(16)

    /** La seule configuration tolérée par ce matériel (mesurée). */
    private val camSize = Size(1280, 720)

    private var active = false

    /** Quad plein écran (triangle strip) + coords de texture de base. */
    private val quadVertices: FloatBuffer = floatBuffer(
        floatArrayOf(
            -1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f,
        ),
    )
    private val quadTexCoords: FloatBuffer = floatBuffer(
        floatArrayOf(
            0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f,
        ),
    )

    private var frames = 0

    /** Nombre d'images déjà rendues (preuve de vie pour la choréographie dual). */
    val renderedFrames: Int get() = frames
    val isActive: Boolean get() = active

    /** Prêt = la PREMIÈRE image est réellement rendue (pas « session configurée » :
     * leçon du double flux — une session qui se configure ne prouve rien). */
    private var onReadyCb: ((Boolean) -> Unit)? = null
    private var readyFired = false
    private var lastError: String? = null

    private fun fireReady(ok: Boolean) = activity.runOnUiThread {
        if (readyFired) return@runOnUiThread
        readyFired = true
        onReadyCb?.invoke(ok)
    }

    private fun fail(message: String) {
        CamLog.e("gl", "échec : $message")
        lastError = message
        close { fireReady(false) }
    }

    // ------------------------------------------------------------------
    // Ouverture
    // ------------------------------------------------------------------

    /** Version canal (test simple) : répond avec la texture, ou l'erreur. */
    fun open(back: Boolean, rotationDeg: Int, mirrorParam: Boolean, result: MethodChannel.Result) {
        open(back, rotationDeg, mirrorParam) { ok ->
            if (ok) result.success(mapOf("textureId" to textureId))
            else result.error("GL_UNSUPPORTED", lastError ?: "échec GPU", null)
        }
    }

    /** Version callback (réutilisée par le double flux GPU — étape 2). */
    fun open(back: Boolean, rotationDeg: Int, mirrorParam: Boolean, onReady: (Boolean) -> Unit) {
        onReadyCb = onReady
        readyFired = false
        lastError = null
        CamLog.i(
            "gl",
            "=== ÉTAPE 1 : OUVERTURE APERÇU GPU (une caméra, ${if (back) "arrière" else "avant"}, " +
                "rotation=$rotationDeg°, miroir=$mirrorParam) ===",
        )
        try {
            val id = firstCamera(
                if (back) CameraCharacteristics.LENS_FACING_BACK
                else CameraCharacteristics.LENS_FACING_FRONT,
            )
            if (id == null) {
                fail("Caméra introuvable")
                return
            }
            val chars = manager.getCameraCharacteristics(id)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            mirror = mirrorParam
            fpsRange = pickFpsRange(chars)

            // Sortie PORTRAIT (720×1280 = 9:16). L'orientation est ici un
            // PARAMÈTRE testable (0/90/180/270) au lieu d'être devinée : Jay
            // essaie en direct et dit laquelle est droite (fini les 5 essais à
            // l'aveugle). On tourne l'ÉCHANTILLONNAGE de -rotationDeg pour faire
            // tourner l'IMAGE de +rotationDeg. Miroir inclus.
            outW = camSize.height
            outH = camSize.width

            Matrix.setIdentityM(texRotMatrix, 0)
            Matrix.translateM(texRotMatrix, 0, 0.5f, 0.5f, 0f)
            Matrix.rotateM(texRotMatrix, 0, -rotationDeg.toFloat(), 0f, 0f, 1f)
            if (mirror) Matrix.scaleM(texRotMatrix, 0, -1f, 1f, 1f)
            Matrix.translateM(texRotMatrix, 0, -0.5f, -0.5f, 0f)

            // Texture Flutter — thread principal obligatoire. Rotation déjà faite
            // dans le GPU → on annonce rotation 0 au Dart.
            val p = textureRegistry.createSurfaceProducer()
            p.setSize(outW, outH)
            producer = p
            textureId = p.id()
            previewInfoSink(previewKey, outW, outH, 0)
            CamLog.i(
                "gl",
                "texture Flutter ${p.id()} (sortie ${outW}×$outH portrait), " +
                    "capteur $sensorOrientation°, miroir=$mirror",
            )

            glThread = HandlerThread("nv-gl").also { it.start() }
            glHandler = Handler(glThread!!.looper)
            camThread = HandlerThread("nv-gl-cam").also { it.start() }
            camHandler = Handler(camThread!!.looper)

            glHandler!!.post {
                try {
                    initEgl(p.surface)
                    initGl()
                    val st = SurfaceTexture(oesTexId)
                    st.setDefaultBufferSize(camSize.width, camSize.height)
                    st.setOnFrameAvailableListener({ onFrame() }, glHandler)
                    cameraSurfaceTexture = st
                    cameraSurface = Surface(st)
                    CamLog.i("gl", "EGL + GL prêts, SurfaceTexture caméra créée")
                    openCamera(id)
                } catch (e: Exception) {
                    fail("init GL : ${e.message}")
                }
            }
        } catch (e: Exception) {
            fail("exception à l'ouverture : ${e.message}")
        }
    }

    private fun openCamera(id: String) {
        val surface = cameraSurface ?: return
        manager.openCamera(
            id,
            object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    CamLog.i("gl", "caméra ouverte")
                    device = cam
                    // createCaptureSession peut lever synchroniquement une
                    // CameraAccessException (ex. « Error configuring streams:
                    // Function not implemented (-38) » quand deux ouvertures se
                    // chevauchent). Sans ce try/catch, elle remontait NON
                    // rattrapée sur le thread caméra → crash (journal Jay,
                    // v0.9.10). Un souci caméra ne doit jamais tuer l'app.
                    try {
                        @Suppress("DEPRECATION")
                        cam.createCaptureSession(
                            listOf(surface),
                            object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: CameraCaptureSession) {
                                session = s
                                val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                    .apply {
                                        addTarget(surface)
                                        fpsRange?.let {
                                            set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
                                            CamLog.i("gl", "plage d'images forcée à $it i/s")
                                        }
                                    }
                                runCatching {
                                    s.setRepeatingRequest(req.build(), null, camHandler)
                                }.onFailure {
                                    fail("flux répétitif refusé : ${it.message}")
                                    return
                                }
                                active = true
                                CamLog.i("gl", "session GPU configurée — attente de la 1re image")
                                // « Prêt » sera signalé par onFrame à la 1re image
                                // RENDUE : une session configurée ne prouve rien
                                // (leçon du double flux). Ça sécurise aussi la
                                // choréographie dual (ouvrir la 2e caméra seulement
                                // quand la 1re délivre vraiment).
                            }

                            override fun onConfigureFailed(s: CameraCaptureSession) {
                                fail("session refusée")
                            }
                        },
                        camHandler,
                    )
                    } catch (e: Exception) {
                        fail("création de session impossible : ${e.message}")
                    }
                }

                override fun onDisconnected(cam: CameraDevice) {
                    CamLog.e("gl", "caméra déconnectée")
                    active = false
                    runCatching { cam.close() }
                }

                override fun onError(cam: CameraDevice, error: Int) {
                    CamLog.e("gl", "erreur caméra $error")
                    active = false
                    runCatching { cam.close() }
                    fail("erreur caméra $error")
                }
            },
            camHandler,
        )
    }

    // ------------------------------------------------------------------
    // Rendu d'une image (thread GL)
    // ------------------------------------------------------------------

    private fun onFrame() {
        val st = cameraSurfaceTexture ?: return
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        try {
            st.updateTexImage()
            st.getTransformMatrix(stMatrix)

            // 1) Aperçu affiché.
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            drawCurrentFrame()
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)

            // 2) Encodeur vidéo (étape 4) : MÊME image, dessinée dans la surface
            // d'entrée du codec, avec le timestamp du capteur → un .mp4 par caméra.
            if (recording) encodeCurrentFrame(st.timestamp)

            frames++
            if (frames == 1) {
                CamLog.i("gl", "PREMIÈRE image rendue par le GPU")
                fireReady(true) // prêt = ça rend vraiment
            }
            if (frames % 120 == 0) CamLog.i("gl", "$frames images rendues (GPU)")
        } catch (e: Exception) {
            CamLog.e("gl", "rendu d'une image impossible", e)
        }
    }

    /**
     * Dessine l'image courante (dernière `updateTexImage`) dans la surface EGL
     * ACTUELLEMENT courante. Le programme, la texture OES et les buffers sont des
     * objets de CONTEXTE (partagés entre les deux surfaces du même contexte), donc
     * ce même dessin sert l'aperçu ET l'encodeur.
     */
    private fun drawCurrentFrame() {
        GLES20.glViewport(0, 0, outW, outH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glUseProgram(program)

        // Positions : quad plein écran, pas de transformation.
        Matrix.setIdentityM(mvpMatrix, 0)
        GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, mvpMatrix, 0)
        GLES20.glUniformMatrix4fv(uStMatrixLoc, 1, false, stMatrix, 0)
        GLES20.glUniformMatrix4fv(uTexRotLoc, 1, false, texRotMatrix, 0)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)

        quadVertices.position(0)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        quadTexCoords.position(0)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    // ------------------------------------------------------------------
    // Photo — la dernière image, rendue en offscreen puis lue (instantané)
    // ------------------------------------------------------------------

    /**
     * Capture la DERNIÈRE image (celle affichée) en JPEG. Rendu dans un
     * framebuffer offscreen au même format que l'aperçu (720×1280, déjà droit),
     * puis `glReadPixels`. Instantané : on ne reparle jamais à la caméra. Bloque
     * l'appelant jusqu'à ~3 s (à lancer hors du thread principal).
     */
    fun capturePhoto(): File? {
        if (!active) return null
        val gl = glHandler ?: return null
        val latch = CountDownLatch(1)
        var out: File? = null
        gl.post {
            out = runCatching { renderToJpeg() }
                .onFailure { CamLog.e("gl", "capture GPU impossible", it) }
                .getOrNull()
            latch.countDown()
        }
        latch.await(3, TimeUnit.SECONDS)
        return out
    }

    /** Rend l'image courante dans un FBO et l'encode en JPEG (thread GL). */
    private fun renderToJpeg(): File? {
        val st = cameraSurfaceTexture ?: return null
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        st.updateTexImage()
        st.getTransformMatrix(stMatrix)

        val fbo = IntArray(1)
        GLES20.glGenFramebuffers(1, fbo, 0)
        val fboTex = IntArray(1)
        GLES20.glGenTextures(1, fboTex, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex[0])
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, outW, outH, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
        )
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[0])
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, fboTex[0], 0,
        )

        GLES20.glViewport(0, 0, outW, outH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        Matrix.setIdentityM(mvpMatrix, 0)
        GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, mvpMatrix, 0)
        GLES20.glUniformMatrix4fv(uStMatrixLoc, 1, false, stMatrix, 0)
        GLES20.glUniformMatrix4fv(uTexRotLoc, 1, false, texRotMatrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)
        quadVertices.position(0)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        quadTexCoords.position(0)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        val buf = ByteBuffer.allocateDirect(outW * outH * 4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(0, 0, outW, outH, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
        buf.rewind()

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glDeleteFramebuffers(1, fbo, 0)
        GLES20.glDeleteTextures(1, fboTex, 0)

        val raw = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        raw.copyPixelsFromBuffer(buf)
        // glReadPixels lit de bas en haut → miroir vertical pour un JPEG droit.
        val flip = android.graphics.Matrix().apply { preScale(1f, -1f) }
        val bmp = Bitmap.createBitmap(raw, 0, 0, outW, outH, flip, false)
        raw.recycle()

        val file = File.createTempFile("nv_gl_${previewKey}_", ".jpg", activity.cacheDir)
        FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        bmp.recycle()
        CamLog.i("gl", "$previewKey : photo GPU écrite (${file.length() / 1024} Ko)")
        return file
    }

    // ------------------------------------------------------------------
    // Vidéo — un encodeur H264 par caméra (étape 4)
    // ------------------------------------------------------------------

    /**
     * Démarre l'enregistrement vidéo de CETTE caméra. Crée le `MediaCodec` H264
     * (surface d'entrée), une surface EGL adossée à cette entrée (même contexte
     * → OES + shader partagés) et le `MediaMuxer`. Tout se fait sur le thread GL
     * (les surfaces EGL sont liées au thread). Renvoie false si le codec refuse.
     */
    fun startRecording(withAudio: Boolean): Boolean {
        if (!active || recording) return false
        val gl = glHandler ?: return false
        val latch = CountDownLatch(1)
        var ok = false
        gl.post {
            ok = runCatching { setupEncoder(withAudio) }.getOrElse {
                CamLog.e("gl", "$previewKey : démarrage encodeur impossible", it)
                releaseEncoder()
                false
            }
            latch.countDown()
        }
        latch.await(3, TimeUnit.SECONDS)
        return ok
    }

    /** Setup du codec + muxer + surface EGL de l'encodeur (thread GL). */
    private fun setupEncoder(withAudio: Boolean): Boolean {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_BITRATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val inputSurface = codec.createInputSurface()
        codec.start()

        val attribs = intArrayOf(EGL14.EGL_NONE)
        val encSurf = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, inputSurface, attribs, 0)
        if (encSurf == EGL14.EGL_NO_SURFACE) {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { inputSurface.release() }
            throw RuntimeException("eglCreateWindowSurface (encodeur) a échoué")
        }

        val file = File.createTempFile("nv_gl_video_${previewKey}_", ".mp4", activity.cacheDir)
        val mux = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        encoder = codec
        encoderInputSurface = inputSurface
        encoderEglSurface = encSurf
        muxer = mux
        videoTrackIndex = -1
        audioTrackIndex = -1
        muxerStarted = false
        videoFile = file
        videoFirstTimestampNs = 0L
        videoFirstWallNs = 0L
        hasAudio = withAudio
        recording = true
        CamLog.i(
            "gl",
            "$previewKey : encodeur vidéo démarré (${outW}×$outH @30, " +
                "${VIDEO_BITRATE / 1_000_000} Mb/s${if (withAudio) " + audio" else ""})",
        )
        return true
    }

    /** Démarre le muxer une fois TOUTES les pistes attendues connues (la vidéo,
     * et l'audio si l'enregistrement en comporte). Appelé sous [muxerLock]. */
    private fun maybeStartMuxer() {
        if (muxerStarted) return
        if (videoTrackIndex < 0) return
        if (hasAudio && audioTrackIndex < 0) return
        muxer?.start()
        muxerStarted = true
    }

    /** La capture audio a échoué : ne plus attendre la piste audio. */
    fun disableAudio() = synchronized(muxerLock) {
        hasAudio = false
        maybeStartMuxer()
    }

    // --- AudioSink : la piste audio PARTAGÉE (thread audio) -----------------

    override fun onAudioFormat(format: MediaFormat) = synchronized(muxerLock) {
        val mux = muxer ?: return
        if (recording && audioTrackIndex < 0) {
            audioTrackIndex = mux.addTrack(format)
            maybeStartMuxer()
        }
    }

    override fun onAudioSample(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        sampleWallNs: Long,
    ) = synchronized(muxerLock) {
        val mux = muxer ?: return
        // Tant qu'aucune image vidéo n'est encodée, il n'y a pas d'origine sur
        // laquelle recaler l'audio : on laisse tomber l'échantillon (le muxer
        // n'a de toute façon pas encore démarré).
        if (!muxerStarted || audioTrackIndex < 0 || videoFirstWallNs == 0L) return
        // Recalage sur l'origine de MA piste vidéo. Sans ça, les deux pistes
        // partaient chacune de zéro alors que l'audio commence ~450 ms plus
        // tard → son en avance sur l'image (retour de Jay, v0.9.20).
        val alignedInfo = MediaCodec.BufferInfo().apply {
            set(
                info.offset,
                info.size,
                ((sampleWallNs - videoFirstWallNs) / 1_000).coerceAtLeast(0),
                info.flags,
            )
        }
        mux.writeSampleData(audioTrackIndex, buffer, alignedInfo)
    }

    /** Dessine l'image courante dans la surface d'entrée du codec + draine. */
    private fun encodeCurrentFrame(timestampNs: Long) {
        val encSurf = encoderEglSurface
        if (encSurf == EGL14.EGL_NO_SURFACE) return
        // Normalise le PTS vidéo sur la 1re image → la piste démarre à ~0, comme
        // la piste audio, pour qu'elles soient alignées dans le fichier.
        if (videoFirstTimestampNs == 0L) {
            videoFirstTimestampNs = timestampNs
            // Même instant, mais sur l'horloge `System.nanoTime` — c'est celle
            // de la capture audio. Sert d'origine COMMUNE aux deux pistes
            // (voir onAudioSample) sans avoir à corréler l'horloge du capteur.
            videoFirstWallNs = System.nanoTime()
        }
        val ptsNs = (timestampNs - videoFirstTimestampNs).coerceAtLeast(0)
        EGL14.eglMakeCurrent(eglDisplay, encSurf, encSurf, eglContext)
        drawCurrentFrame()
        EGLExt.eglPresentationTimeANDROID(eglDisplay, encSurf, ptsNs)
        EGL14.eglSwapBuffers(eglDisplay, encSurf)
        // Repasser sur l'aperçu pour la suite du rendu.
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        drainEncoder(endOfStream = false)
    }

    /** Sort les paquets vidéo encodés du codec vers le muxer (thread GL). */
    private fun drainEncoder(endOfStream: Boolean) {
        val codec = encoder ?: return
        if (endOfStream) runCatching { codec.signalEndOfInputStream() }
        while (true) {
            val outIndex = codec.dequeueOutputBuffer(
                encoderBufferInfo,
                if (endOfStream) 10_000 else 0,
            )
            if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream) break // rien de prêt pour l'instant
                // fin de flux : on continue d'attendre le drain complet
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                synchronized(muxerLock) {
                    if (videoTrackIndex < 0) {
                        videoTrackIndex = muxer?.addTrack(codec.outputFormat) ?: -1
                        maybeStartMuxer()
                    }
                }
            } else if (outIndex >= 0) {
                val encoded = codec.getOutputBuffer(outIndex)
                if (encoded != null) {
                    // Le paquet de config (SPS/PPS) est déjà dans le format du
                    // muxer → ne pas l'écrire comme échantillon.
                    if (encoderBufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        encoderBufferInfo.size = 0
                    }
                    if (encoderBufferInfo.size != 0) {
                        synchronized(muxerLock) {
                            if (muxerStarted && videoTrackIndex >= 0) {
                                encoded.position(encoderBufferInfo.offset)
                                encoded.limit(encoderBufferInfo.offset + encoderBufferInfo.size)
                                muxer?.writeSampleData(videoTrackIndex, encoded, encoderBufferInfo)
                            }
                        }
                    }
                }
                codec.releaseOutputBuffer(outIndex, false)
                if (encoderBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
    }

    /**
     * Arrête l'enregistrement et renvoie le fichier .mp4 (ou null en cas
     * d'échec). Draine la fin de flux puis libère codec + muxer, sur le thread GL.
     */
    fun stopRecording(): File? {
        if (!recording) return null
        val gl = glHandler ?: return null
        val latch = CountDownLatch(1)
        var out: File? = null
        gl.post {
            recording = false
            out = runCatching {
                drainEncoder(endOfStream = true)
                videoFile
            }.getOrElse {
                CamLog.e("gl", "$previewKey : arrêt encodeur", it)
                null
            }
            releaseEncoder()
            latch.countDown()
        }
        latch.await(4, TimeUnit.SECONDS)
        if (out != null) {
            CamLog.i("gl", "$previewKey : vidéo GPU écrite (${(out!!.length()) / 1024} Ko)")
        }
        return out
    }

    /** Libère codec + muxer + surface EGL de l'encodeur (thread GL). */
    private fun releaseEncoder() {
        synchronized(muxerLock) {
            runCatching { if (muxerStarted) muxer?.stop() }
            runCatching { muxer?.release() }
            muxer = null
            videoTrackIndex = -1
            audioTrackIndex = -1
            muxerStarted = false
            hasAudio = false
        }
        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }
        if (encoderEglSurface != EGL14.EGL_NO_SURFACE) {
            runCatching { EGL14.eglDestroySurface(eglDisplay, encoderEglSurface) }
        }
        runCatching { encoderInputSurface?.release() }
        encoder = null
        encoderInputSurface = null
        encoderEglSurface = EGL14.EGL_NO_SURFACE
        recording = false
        // L'aperçu redevient la surface courante : le rendu continue normalement.
        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglSurface != EGL14.EGL_NO_SURFACE) {
            runCatching { EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext) }
        }
    }

    // ------------------------------------------------------------------
    // EGL / GL — installation
    // ------------------------------------------------------------------

    private fun initEgl(surface: Surface) {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw RuntimeException("eglInitialize a échoué")
        }
        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
            numConfigs[0] == 0
        ) {
            throw RuntimeException("aucune configuration EGL")
        }
        val config = configs[0]
        eglConfig = config
        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(
            eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0,
        )
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext a échoué")

        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, config, surface, surfaceAttribs, 0,
        )
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw RuntimeException("eglCreateWindowSurface a échoué")

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw RuntimeException("eglMakeCurrent a échoué")
        }
        CamLog.i("gl", "EGL initialisé (ES2, window surface prête)")
    }

    private fun initGl() {
        program = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTexCoord")
        uMvpLoc = GLES20.glGetUniformLocation(program, "uMvp")
        uStMatrixLoc = GLES20.glGetUniformLocation(program, "uStMatrix")
        uTexRotLoc = GLES20.glGetUniformLocation(program, "uTexRot")

        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        oesTexId = tex[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )
        CamLog.i("gl", "programme GL + texture externe OES prêts (tex=$oesTexId)")
    }

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val status = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            throw RuntimeException("link programme GL : $log")
        }
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw RuntimeException("compilation shader : $log")
        }
        return shader
    }

    // ------------------------------------------------------------------
    // Fermeture
    // ------------------------------------------------------------------

    fun close(onDone: (() -> Unit)? = null) {
        active = false
        val gl = glHandler
        val finish = {
            // Coupe un enregistrement en cours avant de démonter EGL/caméra.
            if (recording || encoder != null) runCatching { releaseEncoder() }
            runCatching { session?.close() }
            runCatching { device?.close() }
            session = null
            device = null
            runCatching { cameraSurface?.release() }
            runCatching { cameraSurfaceTexture?.release() }
            cameraSurface = null
            cameraSurfaceTexture = null
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
                if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                // PAS d'eglTerminate : le display (EGL_DEFAULT_DISPLAY) est
                // partagé par les deux instances en mode double flux GPU ; le
                // terminer casserait le contexte de l'autre caméra. On se
                // contente de détruire NOTRE surface et NOTRE contexte.
            }
            eglDisplay = EGL14.EGL_NO_DISPLAY
            eglContext = EGL14.EGL_NO_CONTEXT
            eglSurface = EGL14.EGL_NO_SURFACE
            glThread?.quitSafely()
            camThread?.quitSafely()
            glThread = null
            camThread = null
            glHandler = null
            camHandler = null
            frames = 0
            activity.runOnUiThread {
                runCatching { producer?.release() }
                producer = null
                textureId = -1
                CamLog.i("gl", "aperçu GPU fermé")
                onDone?.invoke()
            }
        }
        if (gl != null) gl.post { finish() } else finish()
    }

    // ------------------------------------------------------------------
    // Utilitaires
    // ------------------------------------------------------------------

    private fun pickFpsRange(chars: CameraCharacteristics): Range<Int>? {
        val ranges = chars.get(
            CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES,
        ) ?: return null
        return ranges.maxWithOrNull(compareBy<Range<Int>>({ it.lower }, { -it.upper }))
    }

    private fun firstCamera(facing: Int): String? =
        manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.LENS_FACING) == facing
        }

    private fun floatBuffer(data: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder())
            .asFloatBuffer().apply {
                put(data)
                position(0)
            }

    companion object {
        /**
         * Débit vidéo de l'encodeur GPU (étape 4). ~6 Mb/s à 720×1280@30 = bonne
         * qualité pour valider le pipeline. NOTE : au branchement dans le vrai
         * Oneshot (étape 5), réconcilier avec le plafond Supabase (RAPPELS #7 :
         * 3,5 Mb/s pour tenir 61 s sous 50 Mo) — ici pas d'upload, fichier local.
         */
        /**
         * 3,5 Mb/s — MÊME plafond que le chemin CameraX (`NativeCamera`), et
         * pour la même raison : Supabase refuse les fichiers de plus de 50 Mo
         * (StorageException 413, RAPPELS #7). Le Oneshot double produit DEUX
         * vidéos de 61 s max → ~28 Mo chacune à ce débit, contre ~46 Mo aux
         * 6 Mb/s de l'étape 4 (marge trop mince, et deux fichiers à envoyer).
         */
        private const val VIDEO_BITRATE = 3_500_000

        // aTexCoord (0..1) est d'abord tourné/mis en miroir (uTexRot, autour du
        // centre), puis transformé par la matrice de la SurfaceTexture (uStMatrix,
        // recadrage/flip de la texture externe).
        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uMvp;
            uniform mat4 uStMatrix;
            uniform mat4 uTexRot;
            varying vec2 vTex;
            void main() {
                gl_Position = uMvp * aPosition;
                vTex = (uStMatrix * uTexRot * aTexCoord).xy;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTex);
            }
        """
    }
}
