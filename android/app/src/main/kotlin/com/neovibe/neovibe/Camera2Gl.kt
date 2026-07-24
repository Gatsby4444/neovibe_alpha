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
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

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
 * C'est le chemin de GoNext (rendu GPU, ~45 i/s constant), par opposition au
 * rendu logiciel de [Camera2Dual] (`lockCanvas`, ~20-27 i/s + freezes).
 *
 * Ici on ne fait QUE l'aperçu d'UNE caméra. Le double flux (étape 2), la photo
 * (étape 3) et la vidéo (étape 4) viennent après, une fois cette base validée
 * sur l'appareil de Jay. Ce qu'il faut vérifier au test : **fluidité** et
 * **orientation** (pas pivoté ni en miroir).
 *
 * Thread : tout le GL vit sur un thread dédié ([glHandler]) avec son contexte
 * EGL. Les API Flutter (création de la texture) restent sur le thread principal.
 */
@SuppressLint("MissingPermission") // permission caméra déjà accordée
class Camera2Gl(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    private val previewInfoSink: (key: String, w: Int, h: Int, rot: Int) -> Unit,
) {
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

    // GL program
    private var program = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uMvpLoc = 0
    private var uStMatrixLoc = 0

    private val stMatrix = FloatArray(16)
    private val mvpMatrix = FloatArray(16)

    /** La seule configuration tolérée par ce matériel (mesurée). */
    private val camSize = Size(1280, 720)

    private var active = false

    /** Quad plein écran (triangle strip) + coords de texture. */
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

    // ------------------------------------------------------------------
    // Ouverture
    // ------------------------------------------------------------------

    fun open(back: Boolean, result: MethodChannel.Result) {
        CamLog.i("gl", "=== ÉTAPE 1 : OUVERTURE APERÇU GPU (une caméra, ${if (back) "arrière" else "avant"}) ===")
        try {
            val id = firstCamera(
                if (back) CameraCharacteristics.LENS_FACING_BACK
                else CameraCharacteristics.LENS_FACING_FRONT,
            )
            if (id == null) {
                result.error("GL_UNSUPPORTED", "Caméra introuvable", null)
                return
            }
            val chars = manager.getCameraCharacteristics(id)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            mirror = !back
            fpsRange = pickFpsRange(chars)

            // La sortie affichée est portrait (le capteur est paysage → on tourne
            // dans le shader). 1280×720 tourné = 720×1280 = 9:16 exact.
            val turned = sensorOrientation % 180 != 0
            val outW = if (turned) camSize.height else camSize.width
            val outH = if (turned) camSize.width else camSize.height

            // Texture Flutter — thread principal obligatoire.
            val p = textureRegistry.createSurfaceProducer()
            p.setSize(outW, outH)
            producer = p
            textureId = p.id()
            previewInfoSink("gl", outW, outH, 0)
            CamLog.i("gl", "texture Flutter ${p.id()} (${outW}×$outH), capteur $sensorOrientation°, miroir=$mirror")

            glThread = HandlerThread("nv-gl").also { it.start() }
            glHandler = Handler(glThread!!.looper)
            camThread = HandlerThread("nv-gl-cam").also { it.start() }
            camHandler = Handler(camThread!!.looper)

            glHandler!!.post {
                try {
                    initEgl(p.surface)
                    initGl()
                    // SurfaceTexture créée sur le thread GL (le texture OES doit
                    // exister dans CE contexte).
                    val st = SurfaceTexture(oesTexId)
                    st.setDefaultBufferSize(camSize.width, camSize.height)
                    st.setOnFrameAvailableListener({ onFrame() }, glHandler)
                    cameraSurfaceTexture = st
                    cameraSurface = Surface(st)
                    CamLog.i("gl", "EGL + GL prêts, SurfaceTexture caméra créée")
                    openCamera(id, result)
                } catch (e: Exception) {
                    CamLog.e("gl", "init GL impossible", e)
                    activity.runOnUiThread {
                        close { result.error("GL_UNSUPPORTED", "init GL : ${e.message}", null) }
                    }
                }
            }
        } catch (e: Exception) {
            CamLog.e("gl", "exception à l'ouverture", e)
            close { result.error("GL_UNSUPPORTED", e.message, null) }
        }
    }

    private fun openCamera(id: String, result: MethodChannel.Result) {
        val surface = cameraSurface ?: return
        manager.openCamera(
            id,
            object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    CamLog.i("gl", "caméra ouverte")
                    device = cam
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
                                    CamLog.e("gl", "flux répétitif refusé", it)
                                    activity.runOnUiThread {
                                        close { result.error("GL_UNSUPPORTED", "flux refusé", null) }
                                    }
                                    return
                                }
                                active = true
                                CamLog.i("gl", "session GPU configurée — aperçu en cours")
                                activity.runOnUiThread {
                                    result.success(mapOf("textureId" to textureId))
                                }
                            }

                            override fun onConfigureFailed(s: CameraCaptureSession) {
                                CamLog.e("gl", "session REFUSÉE")
                                activity.runOnUiThread {
                                    close { result.error("GL_UNSUPPORTED", "session refusée", null) }
                                }
                            }
                        },
                        camHandler,
                    )
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
                    activity.runOnUiThread {
                        close { result.error("GL_UNSUPPORTED", "erreur caméra $error", null) }
                    }
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

            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            GLES20.glViewport(0, 0, producerWidth(), producerHeight())
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

            GLES20.glUseProgram(program)

            // MVP : rotation portrait + miroir éventuel (caméra frontale).
            Matrix.setIdentityM(mvpMatrix, 0)
            Matrix.rotateM(mvpMatrix, 0, sensorOrientation.toFloat(), 0f, 0f, 1f)
            if (mirror) Matrix.scaleM(mvpMatrix, 0, -1f, 1f, 1f)

            GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, mvpMatrix, 0)
            GLES20.glUniformMatrix4fv(uStMatrixLoc, 1, false, stMatrix, 0)

            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)

            quadVertices.position(0)
            GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
            GLES20.glEnableVertexAttribArray(aPositionLoc)
            quadTexCoords.position(0)
            GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
            GLES20.glEnableVertexAttribArray(aTexCoordLoc)

            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

            EGL14.eglSwapBuffers(eglDisplay, eglSurface)

            frames++
            if (frames == 1) CamLog.i("gl", "PREMIÈRE image rendue par le GPU")
            if (frames % 120 == 0) CamLog.i("gl", "$frames images rendues (GPU)")
        } catch (e: Exception) {
            CamLog.e("gl", "rendu d'une image impossible", e)
        }
    }

    private fun producerWidth(): Int {
        val turned = sensorOrientation % 180 != 0
        return if (turned) camSize.height else camSize.width
    }

    private fun producerHeight(): Int {
        val turned = sensorOrientation % 180 != 0
        return if (turned) camSize.width else camSize.height
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
                EGL14.eglTerminate(eglDisplay)
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
        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uMvp;
            uniform mat4 uStMatrix;
            varying vec2 vTex;
            void main() {
                gl_Position = uMvp * aPosition;
                vTex = (uStMatrix * aTexCoord).xy;
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
