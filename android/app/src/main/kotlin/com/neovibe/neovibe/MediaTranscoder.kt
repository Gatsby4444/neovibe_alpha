package com.neovibe.neovibe

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
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
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Recompresse une vidéo de la galerie pour un **album** (Jay, 2026-09-15) :
 * rognée entre deux instants, recadrée / tournée / redressée au ratio de la
 * publication (les coins de `CropGeometry`), passée par **la même formule de
 * couleurs** que l'aperçu et l'export photo (`shaders/album_grade.frag`), avec
 * le calque des textes et autocollants brûlé dessus, et ramenée à ≤ 1080 px de
 * large et 3,5 Mbit/s — le plafond des Cards (`NativeCamera.VIDEO_BITRATE`,
 * limite d'upload 50 Mo, `RAPPELS.md` #7).
 *
 * ### Le chemin
 *
 * `MediaExtractor` → décodeur `MediaCodec` (sortie sur une `SurfaceTexture`
 * OES) → **un shader GL** (recadrage par coordonnées de texture, rotation,
 * matrice 4×5, vignette) → encodeur H.264 sur sa `Surface` d'entrée →
 * `MediaMuxer`. L'audio AAC est **recopié tel quel** (rogné aux mêmes
 * instants), entrelacé avec la vidéo pour que le fichier se lise en flux.
 *
 * Même famille de code que `Camera2Gl` (EGL, encodeur, drain) — et
 * volontairement **séparé** : le chemin caméra n'est pas touché, et ceci
 * n'a ni aperçu, ni matériel, ni cycle de vie d'activité. Tout est
 * synchrone, sur le fil de travail de [NativeMedia].
 *
 * ### Ce qu'il ne fait pas
 *
 * - Une piste audio qui n'est pas de l'AAC (rare sur un téléphone) n'est pas
 *   transcodée : la vidéo sort **sans son**, et le résultat le dit.
 * - Le rendu est borné dans le temps : une image qui n'arrive pas en 3 s ou
 *   un encodeur qui ne rend rien fait échouer la conversion au lieu de
 *   geler le fil (leçon du 2026-08-31 dans `Camera2Gl.drainEncoder`).
 */
object MediaTranscoder {

    class Params(
        val source: File,
        val dest: File,
        val startMs: Int,
        val endMs: Int,
        /**
         * Les quatre coins du cadre — haut-gauche, haut-droit, bas-gauche,
         * bas-droit, soit 8 nombres — en fractions de l'image AFFICHÉE
         * (rotation appliquée). Calculés par `CropGeometry.corners` côté Dart :
         * ils portent le recadrage, le zoom, les quarts de tour et le
         * redressement d'un seul tenant.
         */
        val corners: FloatArray,
        val outWidth: Int,
        val outHeight: Int,
        /**
         * Le contrat `ColorGrade.toUniforms()` : 24 nombres — la matrice 4×4
         * (colonnes), quatre offsets en 0..1, puis ombres, hautes lumières,
         * netteté, vignette.
         */
        val uniforms: FloatArray,
        /** Le calque des textes et autocollants, un PNG à la taille de sortie ; nul si aucun. */
        val overlayPath: String?,
        /**
         * La rotation déclarée par le fichier (0, 90, 180, 270), lue par la
         * SONDE (`MediaMetadataRetriever`) et passée par Dart.
         *
         * 🔴 **Elle n'est plus lue ici, sur le format de la piste — corrigé le
         * 2026-09-15 après le test de Jay.** `MediaExtractor.getTrackFormat`
         * ne portait pas `KEY_ROTATION` sur son Xiaomi : la rotation valait 0,
         * rien n'était défait, et une vidéo filmée en portrait sortait couchée
         * — exactement l'allure du fichier tel qu'il est stocké.
         */
        val rotation: Int,
    )

    class Result(val ok: Boolean, val message: String, val durationMs: Int, val hasAudio: Boolean)

    private const val BITRATE = NativeCamera.VIDEO_BITRATE
    private const val FRAME_TIMEOUT_MS = 3_000L
    private const val CODEC_TIMEOUT_US = 10_000L

    fun run(p: Params, onProgress: (Float) -> Unit = {}): Result {
        var extractor: MediaExtractor? = null
        var audioExtractor: MediaExtractor? = null
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var decoderSurface: Surface? = null
        var surfaceTexture: SurfaceTexture? = null
        var encoderSurface: Surface? = null
        val gl = Gl()
        var hasAudio = false
        try {
            extractor = MediaExtractor().apply { setDataSource(p.source.path) }
            val videoTrack = findTrack(extractor, "video/")
            if (videoTrack < 0) return Result(false, "aucune piste vidéo", 0, false)
            val inFormat = extractor.getTrackFormat(videoTrack)
            val rotation = p.rotation
            // ⚠️ La rotation est défaite par NOTRE shader. Certains décodeurs
            // l'appliquent eux-mêmes quand ils rendent sur une Surface si le
            // format la porte : on la retire du format pour qu'aucun ne le
            // fasse, sinon elle serait appliquée deux fois.
            inFormat.setInteger(MediaFormat.KEY_ROTATION, 0)
            val fps = if (inFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                inFormat.getInteger(MediaFormat.KEY_FRAME_RATE).coerceIn(15, 60)
            } else 30

            // Piste audio : recopiée si c'est de l'AAC, sinon abandonnée.
            val audioTrack = findTrack(extractor, "audio/")
            var audioFormat: MediaFormat? = null
            if (audioTrack >= 0) {
                val f = extractor.getTrackFormat(audioTrack)
                if (f.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC) {
                    audioFormat = f
                    audioExtractor = MediaExtractor().apply {
                        setDataSource(p.source.path)
                        selectTrack(audioTrack)
                        seekTo(p.startMs * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    }
                    hasAudio = true
                }
            }

            // Sortie paire : les encodeurs H.264 n'aiment pas les tailles impaires.
            val outW = p.outWidth and 1.inv()
            val outH = p.outHeight and 1.inv()

            // 1. L'encodeur, et sa surface d'entrée — c'est la fenêtre EGL.
            val outFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
            encoderSurface = encoder.createInputSurface()
            encoder.start()

            // 2. EGL sur la surface de l'encodeur, puis la texture OES qui reçoit
            //    les images décodées.
            val srcW = inFormat.getInteger(MediaFormat.KEY_WIDTH)
            val srcH = inFormat.getInteger(MediaFormat.KEY_HEIGHT)
            gl.init(encoderSurface, p, rotation, srcW, srcH)
            surfaceTexture = SurfaceTexture(gl.oesTexId)
            val frames = FrameGate()
            surfaceTexture.setOnFrameAvailableListener { frames.signal() }
            decoderSurface = Surface(surfaceTexture)

            // 3. Le décodeur, qui dessine dans cette surface.
            decoder = MediaCodec.createDecoderByType(inFormat.getString(MediaFormat.KEY_MIME)!!).apply {
                configure(inFormat, decoderSurface, null, 0)
                start()
            }
            extractor.selectTrack(videoTrack)
            extractor.seekTo(p.startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            p.dest.parentFile?.mkdirs()
            val tmp = File(p.dest.path + ".part")
            muxer = MediaMuxer(tmp.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val mux = Muxing(muxer, audioFormat)

            // 4. La boucle : nourrir le décodeur, rendre chaque image, encoder.
            val info = MediaCodec.BufferInfo()
            val startUs = p.startMs * 1000L
            val endUs = p.endMs * 1000L
            var inputDone = false
            var outputDone = false
            var lastPtsUs = -1L
            var rendered = 0
            val stMatrix = FloatArray(16)
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(CODEC_TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buf = decoder.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        val sampleUs = extractor.sampleTime
                        if (size < 0 || sampleUs > endUs) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, size, sampleUs, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = decoder.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) continue
                if (outIndex < 0) continue
                val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                val ptsUs = info.presentationTimeUs
                // Les images d'avant le début (depuis l'image-clé précédente)
                // sont décodées mais pas rendues ; celles d'après la fin non plus.
                val render = info.size > 0 && ptsUs >= startUs && ptsUs <= endUs
                decoder.releaseOutputBuffer(outIndex, render)
                if (render) {
                    if (!frames.await(FRAME_TIMEOUT_MS)) {
                        return Result(false, "image jamais rendue par le décodeur", 0, hasAudio)
                    }
                    surfaceTexture.updateTexImage()
                    surfaceTexture.getTransformMatrix(stMatrix)
                    val outPtsUs = ptsUs - startUs
                    gl.draw(stMatrix)
                    EGLExt.eglPresentationTimeANDROID(gl.display, gl.surface, outPtsUs * 1000L)
                    EGL14.eglSwapBuffers(gl.display, gl.surface)
                    lastPtsUs = outPtsUs
                    rendered++
                    drainEncoder(encoder, mux, endOfStream = false)
                    // L'audio suit la vidéo, avec une demi-seconde d'avance : le
                    // fichier reste entrelacé, donc lisible en flux.
                    audioExtractor?.let { mux.writeAudioUpTo(it, startUs, endUs, outPtsUs + 500_000L) }
                    onProgress(((ptsUs - startUs).toFloat() / (endUs - startUs)).coerceIn(0f, 1f))
                }
                if (eos) outputDone = true
            }
            if (rendered == 0) return Result(false, "aucune image dans l'intervalle", 0, hasAudio)
            drainEncoder(encoder, mux, endOfStream = true)
            audioExtractor?.let { mux.writeAudioUpTo(it, startUs, endUs, Long.MAX_VALUE) }
            mux.finish()
            muxer = null
            if (!tmp.renameTo(p.dest)) return Result(false, "renommage impossible", 0, hasAudio)
            return Result(true, "ok", ((lastPtsUs / 1000L) + 1000L / fps).toInt(), hasAudio)
        } catch (e: Exception) {
            return Result(false, e.message ?: e.javaClass.simpleName, 0, hasAudio)
        } finally {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            runCatching { muxer?.release() }
            runCatching { decoderSurface?.release() }
            runCatching { surfaceTexture?.release() }
            gl.release()
            runCatching { encoderSurface?.release() }
            runCatching { extractor?.release() }
            runCatching { audioExtractor?.release() }
        }
    }

    private fun findTrack(extractor: MediaExtractor, prefix: String): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(prefix)) return i
        }
        return -1
    }

    /** Sort les paquets encodés vers le muxer. Borné à la fin de flux. */
    private fun drainEncoder(encoder: MediaCodec, mux: Muxing, endOfStream: Boolean) {
        if (endOfStream) runCatching { encoder.signalEndOfInputStream() }
        val info = MediaCodec.BufferInfo()
        val limite = System.nanoTime() + 4_000_000_000L
        while (true) {
            if (endOfStream && System.nanoTime() > limite) {
                throw RuntimeException("fin de flux jamais signalée par l'encodeur")
            }
            val outIndex = encoder.dequeueOutputBuffer(info, if (endOfStream) CODEC_TIMEOUT_US else 0)
            if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream) break
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                mux.videoFormatKnown(encoder.outputFormat)
            } else if (outIndex >= 0) {
                val encoded = encoder.getOutputBuffer(outIndex)
                if (encoded != null && info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                ) {
                    mux.writeVideo(encoded, info)
                }
                encoder.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
    }

    /** Le muxer et ses deux pistes ; il ne démarre qu'une fois la vidéo connue. */
    private class Muxing(private val muxer: MediaMuxer, audioFormat: MediaFormat?) {
        private var videoTrack = -1
        private var audioTrack = -1
        private var started = false
        private val audioBuffer = ByteBuffer.allocateDirect(256 * 1024)
        private val audioInfo = MediaCodec.BufferInfo()
        private var audioDone = false

        init {
            if (audioFormat != null) audioTrack = muxer.addTrack(audioFormat)
        }

        fun videoFormatKnown(format: MediaFormat) {
            if (videoTrack >= 0) return
            videoTrack = muxer.addTrack(format)
            muxer.start()
            started = true
        }

        fun writeVideo(buf: ByteBuffer, info: MediaCodec.BufferInfo) {
            if (!started) return
            buf.position(info.offset)
            buf.limit(info.offset + info.size)
            muxer.writeSampleData(videoTrack, buf, info)
        }

        /** Recopie les échantillons audio jusqu'à [untilOutUs] (temps de sortie). */
        fun writeAudioUpTo(extractor: MediaExtractor, startUs: Long, endUs: Long, untilOutUs: Long) {
            if (!started || audioTrack < 0 || audioDone) return
            while (true) {
                val sampleUs = extractor.sampleTime
                if (sampleUs < 0) { audioDone = true; return }
                if (sampleUs > endUs) { audioDone = true; return }
                val outUs = sampleUs - startUs
                if (outUs > untilOutUs) return
                if (outUs >= 0) {
                    audioBuffer.clear()
                    val size = extractor.readSampleData(audioBuffer, 0)
                    if (size > 0) {
                        audioInfo.set(0, size, outUs, if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                        muxer.writeSampleData(audioTrack, audioBuffer, audioInfo)
                    }
                }
                if (!extractor.advance()) { audioDone = true; return }
            }
        }

        fun finish() {
            if (started) muxer.stop()
            muxer.release()
        }
    }

    /** L'attente d'une image rendue par le décodeur sur la texture. */
    private class FrameGate {
        private val lock = Object()
        private var available = false

        fun signal() = synchronized(lock) {
            available = true
            lock.notifyAll()
        }

        fun await(timeoutMs: Long): Boolean = synchronized(lock) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (!available) {
                val reste = deadline - System.currentTimeMillis()
                if (reste <= 0) return false
                lock.wait(reste)
            }
            available = false
            true
        }
    }

    /** EGL + le programme : recadrage, rotation, matrice de couleurs, vignette. */
    private class Gl {
        var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var context: EGLContext = EGL14.EGL_NO_CONTEXT
        var surface: EGLSurface = EGL14.EGL_NO_SURFACE
        var oesTexId = 0
        private var program = 0
        private var aPosition = 0
        private var aTexCoord = 0
        private var uStMatrix = 0
        private var uColor = 0
        private var uOffset = 0
        private var uShadows = 0
        private var uHighlights = 0
        private var uSharpen = 0
        private var uVignette = 0
        private var uTexel = 0
        private var uOverlay = 0
        private var uHasOverlay = 0
        private var overlayTexId = 0
        private lateinit var vertices: FloatBuffer
        private lateinit var texCoords: FloatBuffer
        private lateinit var uniforms: FloatArray
        private var texelW = 0f
        private var texelH = 0f
        private var outW = 0
        private var outH = 0

        fun init(window: Surface, p: Params, rotation: Int, srcWidth: Int, srcHeight: Int) {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) throw RuntimeException("eglInitialize a échoué")
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGLExt.EGL_RECORDABLE_ANDROID, 1,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) || n[0] == 0) {
                throw RuntimeException("aucune configuration EGL enregistrable")
            }
            val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
            if (context == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext a échoué")
            surface = EGL14.eglCreateWindowSurface(display, configs[0], window, intArrayOf(EGL14.EGL_NONE), 0)
            if (surface == EGL14.EGL_NO_SURFACE) throw RuntimeException("eglCreateWindowSurface a échoué")
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) throw RuntimeException("eglMakeCurrent a échoué")

            program = buildProgram(VERTEX, FRAGMENT)
            aPosition = GLES20.glGetAttribLocation(program, "aPosition")
            aTexCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
            uStMatrix = GLES20.glGetUniformLocation(program, "uStMatrix")
            uColor = GLES20.glGetUniformLocation(program, "uColor")
            uOffset = GLES20.glGetUniformLocation(program, "uOffset")
            uShadows = GLES20.glGetUniformLocation(program, "uShadows")
            uHighlights = GLES20.glGetUniformLocation(program, "uHighlights")
            uSharpen = GLES20.glGetUniformLocation(program, "uSharpen")
            uVignette = GLES20.glGetUniformLocation(program, "uVignette")
            uTexel = GLES20.glGetUniformLocation(program, "uTexel")
            uOverlay = GLES20.glGetUniformLocation(program, "uOverlay")
            uHasOverlay = GLES20.glGetUniformLocation(program, "uHasOverlay")

            val tex = IntArray(1)
            GLES20.glGenTextures(1, tex, 0)
            oesTexId = tex[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

            outW = p.outWidth and 1.inv()
            outH = p.outHeight and 1.inv()
            vertices = floatBuffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
            texCoords = floatBuffer(cropTexCoords(p, rotation))

            if (p.uniforms.size != 24) throw IllegalArgumentException("uniforms : 24 valeurs attendues")
            uniforms = p.uniforms
            // Un texel de la source STOCKÉE, pour la netteté (les voisins sont
            // pris dans le repère de la texture).
            texelW = 1f / srcWidth.coerceAtLeast(1)
            texelH = 1f / srcHeight.coerceAtLeast(1)

            // Le calque des textes et autocollants : une texture 2D, chargée
            // une fois, mélangée par-dessus chaque image.
            val overlay = p.overlayPath?.let { android.graphics.BitmapFactory.decodeFile(it) }
            if (overlay != null) {
                val t = IntArray(1)
                GLES20.glGenTextures(1, t, 0)
                overlayTexId = t[0]
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTexId)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                // `texImage2D` envoie le bitmap tel qu'il est en mémoire Android :
                // alpha PRÉMULTIPLIÉ. Le shader mélange donc en `dst*(1-a) + src`.
                android.opengl.GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, overlay, 0)
                overlay.recycle()
            }
        }

        /**
         * Les coordonnées de texture des quatre coins de sortie, dans l'image
         * STOCKÉE. Les coins arrivent dans l'image AFFICHÉE (`CropGeometry`) :
         * on revient à l'image stockée en défaisant la rotation déclarée par
         * le fichier (lue par la sonde, passée par Dart).
         *
         * ⚠️ Le sens de ce redressement (et le retournement vertical que la
         * SurfaceTexture applique via `uStMatrix`) est à VÉRIFIER SUR APPAREIL,
         * comme le miroir de la frontale l'a été (`RAPPELS.md` #9).
         */
        private fun cropTexCoords(p: Params, rotation: Int): FloatArray {
            // Sommets dans l'ordre de `vertices` : bas-gauche, bas-droit,
            // haut-gauche, haut-droit. Les coins de Dart : haut-gauche,
            // haut-droit, bas-gauche, bas-droit.
            val order = intArrayOf(2, 3, 0, 1)
            val out = FloatArray(8)
            for (i in 0 until 4) {
                val dx = p.corners[order[i] * 2]
                val dy = p.corners[order[i] * 2 + 1]
                // Retour à l'image stockée : l'inverse d'une rotation horaire.
                val (sx, sy) = when (rotation) {
                    90 -> Pair(dy, 1f - dx)
                    180 -> Pair(1f - dx, 1f - dy)
                    270 -> Pair(1f - dy, dx)
                    else -> Pair(dx, dy)
                }
                // Les coordonnées de texture GL ont l'origine EN BAS ; la matrice de
                // la SurfaceTexture (`uStMatrix`) fait le reste.
                out[i * 2] = sx
                out[i * 2 + 1] = 1f - sy
            }
            return out
        }

        fun draw(stMatrix: FloatArray) {
            GLES20.glViewport(0, 0, outW, outH)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)
            GLES20.glUniformMatrix4fv(uStMatrix, 1, false, stMatrix, 0)
            GLES20.glUniformMatrix4fv(uColor, 1, false, uniforms, 0)
            GLES20.glUniform4fv(uOffset, 1, uniforms, 16)
            GLES20.glUniform1f(uShadows, uniforms[20])
            GLES20.glUniform1f(uHighlights, uniforms[21])
            GLES20.glUniform1f(uSharpen, uniforms[22])
            GLES20.glUniform1f(uVignette, uniforms[23])
            GLES20.glUniform2f(uTexel, texelW, texelH)
            GLES20.glUniform1i(uHasOverlay, if (overlayTexId != 0) 1 else 0)
            if (overlayTexId != 0) {
                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTexId)
                GLES20.glUniform1i(uOverlay, 1)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            }
            vertices.position(0)
            GLES20.glVertexAttribPointer(aPosition, 2, GLES20.GL_FLOAT, false, 0, vertices)
            GLES20.glEnableVertexAttribArray(aPosition)
            texCoords.position(0)
            GLES20.glVertexAttribPointer(aTexCoord, 2, GLES20.GL_FLOAT, false, 0, texCoords)
            GLES20.glEnableVertexAttribArray(aTexCoord)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(aPosition)
            GLES20.glDisableVertexAttribArray(aTexCoord)
        }

        fun release() {
            if (display == EGL14.EGL_NO_DISPLAY) return
            runCatching {
                if (overlayTexId != 0) GLES20.glDeleteTextures(1, intArrayOf(overlayTexId), 0)
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
            display = EGL14.EGL_NO_DISPLAY
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

        private fun floatBuffer(data: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(data)
                position(0)
            }

        companion object {
            private const val VERTEX = """
                attribute vec4 aPosition;
                attribute vec2 aTexCoord;
                uniform mat4 uStMatrix;
                varying vec2 vTexCoord;
                varying vec2 vOut;
                void main() {
                    gl_Position = aPosition;
                    vTexCoord = (uStMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
                    vOut = aPosition.xy * 0.5 + 0.5;
                }
            """

            // LA MÊME FORMULE que `shaders/album_grade.frag` (Flutter) : matrice
            // puis offsets, ombres et hautes lumières pondérées par la
            // luminance, netteté par masque flou sur quatre voisins, vignette
            // en smoothstep de 0,45 à 1 (70 % max), puis le calque par-dessus.
            // `vOut` a l'origine en bas (GL) ; le calque et la vignette se lisent
            // avec y inversé pour retrouver l'orientation de l'écran.
            private const val FRAGMENT = """
                #extension GL_OES_EGL_image_external : require
                precision mediump float;
                uniform samplerExternalOES sTexture;
                uniform sampler2D uOverlay;
                uniform int uHasOverlay;
                uniform mat4 uColor;
                uniform vec4 uOffset;
                uniform float uShadows;
                uniform float uHighlights;
                uniform float uSharpen;
                uniform float uVignette;
                uniform vec2 uTexel;
                varying vec2 vTexCoord;
                varying vec2 vOut;
                const vec3 kLuma = vec3(0.2126, 0.7152, 0.0722);
                vec3 graded(vec3 c) {
                    vec4 g = uColor * vec4(c, 1.0) + uOffset;
                    vec3 rgb = clamp(g.rgb, 0.0, 1.0);
                    float luma = dot(rgb, kLuma);
                    float ws = (1.0 - luma) * (1.0 - luma);
                    rgb += uShadows * 0.25 * ws;
                    float wh = luma * luma;
                    rgb += uHighlights * 0.25 * wh;
                    return clamp(rgb, 0.0, 1.0);
                }
                void main() {
                    vec3 rgb = graded(texture2D(sTexture, vTexCoord).rgb);
                    if (uSharpen > 0.0) {
                        vec3 n = graded(texture2D(sTexture, vTexCoord + vec2(uTexel.x, 0.0)).rgb)
                               + graded(texture2D(sTexture, vTexCoord - vec2(uTexel.x, 0.0)).rgb)
                               + graded(texture2D(sTexture, vTexCoord + vec2(0.0, uTexel.y)).rgb)
                               + graded(texture2D(sTexture, vTexCoord - vec2(0.0, uTexel.y)).rgb);
                        rgb = clamp(rgb + uSharpen * 0.8 * (rgb - n * 0.25), 0.0, 1.0);
                    }
                    vec2 screen = vec2(vOut.x, 1.0 - vOut.y);
                    float d = length(screen - vec2(0.5)) / 0.70710678;
                    float t = clamp((d - 0.45) / 0.55, 0.0, 1.0);
                    float s = t * t * (3.0 - 2.0 * t);
                    float a = min(uVignette * 0.7, 0.7) * s;
                    rgb = mix(rgb, vec3(0.0), a);
                    if (uHasOverlay == 1) {
                        vec4 o = texture2D(uOverlay, screen);
                        rgb = rgb * (1.0 - o.a) + o.rgb;
                    }
                    gl_FragColor = vec4(rgb, 1.0);
                }
            """
        }
    }
}
