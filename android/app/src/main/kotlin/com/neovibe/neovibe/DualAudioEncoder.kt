package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import java.nio.ByteBuffer

/**
 * Capture audio PARTAGÉE pour la vidéo double GPU (étape 4).
 *
 * Il n'y a qu'UNE scène sonore et qu'un micro : on capture le son **une seule
 * fois**, on l'encode en AAC **une seule fois**, et on écrit les MÊMES paquets
 * dans les DEUX muxers (recto + verso). Chaque vidéo reçoit ainsi sa propre
 * piste audio, identique. Deux `AudioRecord` sur le même micro se battraient —
 * d'où le partage.
 *
 * Un thread dédié (`nv-audio`) lit le PCM du micro → encodeur AAC → distribue
 * le format puis les échantillons à chaque [AudioSink]. Les sinks (les instances
 * [Camera2Gl]) sérialisent l'accès à leur muxer (non thread-safe).
 */
@SuppressLint("MissingPermission") // permission micro demandée en amont (Dart)
class DualAudioEncoder(private val sinks: List<AudioSink>) {

    /** Un consommateur de la piste audio (un muxer côté [Camera2Gl]). */
    interface AudioSink {
        /** Format AAC connu → ajouter une piste audio au muxer. */
        fun onAudioFormat(format: MediaFormat)

        /**
         * Un paquet AAC encodé à écrire dans la piste audio.
         *
         * [sampleWallNs] = instant RÉEL de l'échantillon (`System.nanoTime`).
         * Indispensable : la capture audio démarre quelques centaines de ms
         * APRÈS les encodeurs vidéo (~450 ms mesurées dans le journal de Jay,
         * v0.9.20). Chaque piste remise à zéro de son côté, l'audio se
         * retrouvait en AVANCE d'autant. Le sink recale donc l'horodatage sur
         * SA propre origine vidéo, à partir de cet instant réel.
         */
        fun onAudioSample(
            buffer: ByteBuffer,
            info: MediaCodec.BufferInfo,
            sampleWallNs: Long,
        )
    }

    private var record: AudioRecord? = null
    private var codec: MediaCodec? = null
    private var thread: Thread? = null

    @Volatile
    private var running = false

    /** Origine des horodatages audio (première lecture) → piste démarre à ~0. */
    private var firstNs = 0L

    fun start(): Boolean {
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, ENCODING)
        if (minBuf <= 0) {
            CamLog.e("gl", "audio : getMinBufferSize invalide ($minBuf)")
            return false
        }
        val bufSize = maxOf(minBuf, SAMPLE_RATE) // ~0,5 s de marge (16 bits mono)
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_IN, ENCODING, bufSize,
            )
        } catch (e: Exception) {
            CamLog.e("gl", "audio : AudioRecord impossible", e)
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            CamLog.e("gl", "audio : AudioRecord non initialisé (permission micro ?)")
            rec.release()
            return false
        }

        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1,
        ).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufSize)
        }
        val enc = try {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
        } catch (e: Exception) {
            CamLog.e("gl", "audio : encodeur AAC impossible", e)
            rec.release()
            return false
        }

        record = rec
        codec = enc
        running = true
        firstNs = 0L
        rec.startRecording()
        thread = Thread({ loop() }, "nv-audio").also { it.start() }
        CamLog.i("gl", "audio : capture partagée démarrée ($SAMPLE_RATE Hz mono AAC)")
        return true
    }

    private fun loop() {
        val rec = record ?: return
        val enc = codec ?: return
        val info = MediaCodec.BufferInfo()
        val pcm = ByteArray(2048)
        while (running) {
            val read = rec.read(pcm, 0, pcm.size)
            if (read > 0) feedInput(enc, pcm, read, endOfStream = false)
            drain(enc, info)
        }
        // Fin de flux : marque la fin côté entrée puis draine le reste.
        feedInput(enc, pcm, 0, endOfStream = true)
        drain(enc, info)
    }

    private fun feedInput(enc: MediaCodec, pcm: ByteArray, len: Int, endOfStream: Boolean) {
        val inIndex = enc.dequeueInputBuffer(10_000)
        if (inIndex < 0) return
        val inBuf = enc.getInputBuffer(inIndex) ?: return
        inBuf.clear()
        if (len > 0) inBuf.put(pcm, 0, len)
        if (firstNs == 0L) firstNs = System.nanoTime()
        val ptsUs = (System.nanoTime() - firstNs) / 1000
        val flags = if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
        enc.queueInputBuffer(inIndex, 0, len, ptsUs, flags)
    }

    private fun drain(enc: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val outIndex = enc.dequeueOutputBuffer(info, 0)
            if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val fmt = enc.outputFormat
                sinks.forEach { it.onAudioFormat(fmt) }
            } else if (outIndex >= 0) {
                val buf = enc.getOutputBuffer(outIndex)
                if (buf != null) {
                    // Le paquet de config (csd) est déjà dans le format → pas un
                    // échantillon.
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0) {
                        // Instant réel de l'échantillon : les PTS sortis du
                        // codec sont comptés depuis `firstNs`, on remonte donc
                        // à l'horloge absolue pour que chaque sink puisse se
                        // recaler sur SA piste vidéo.
                        val sampleWallNs = firstNs + info.presentationTimeUs * 1_000
                        sinks.forEach { sink ->
                            // Repositionner AVANT chaque écriture (le muxer
                            // consomme position→limit).
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            sink.onAudioSample(buf, info, sampleWallNs)
                        }
                    }
                }
                enc.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
    }

    fun stop() {
        if (!running && thread == null) return
        running = false
        runCatching { thread?.join(1000) }
        thread = null
        runCatching { record?.stop() }
        runCatching { record?.release() }
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        record = null
        codec = null
        CamLog.i("gl", "audio : capture partagée arrêtée")
    }

    companion object {
        private const val SAMPLE_RATE = 44_100
        private const val CHANNEL_IN = AudioFormat.CHANNEL_IN_MONO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        private const val BIT_RATE = 96_000
    }
}
