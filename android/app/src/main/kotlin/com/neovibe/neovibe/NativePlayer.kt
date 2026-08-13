package com.neovibe.neovibe

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Lecteur vidéo **natif** des médias scellés — décision de Jay du 2026-08-12.
 *
 * ### Pourquoi il existe
 *
 * La v0.9.55 lisait les vidéos par un serveur HTTP local qui déchiffrait en
 * Dart, sur l'isolate qui dessine l'écran. Résultat mesuré : ~2,7 Mo/s et une
 * interface qui saccade. Ici, ExoPlayer lit le format scellé **directement**
 * ([SealedDataSource]), déchiffre par les instructions AES du processeur, et
 * travaille sur ses propres fils. L'isolate Dart ne voit plus un octet de
 * vidéo passer.
 *
 * Trois pièces disparaissent avec le serveur : le socket sur `127.0.0.1`, le
 * jeton qui protégeait l'URL des autres applications du téléphone, et
 * l'exception `cleartext` du manifeste.
 *
 * ### Ce qu'il ne fait pas
 *
 * Il ne remplace pas `video_player` partout : l'aperçu de capture et les vidéos
 * éphémères de messagerie (URL distante) le gardent. Ce lecteur-ci ne sert que
 * ce qu'ExoPlayer ne saurait pas ouvrir seul — un média scellé — plus le
 * fichier en clair d'un Enregistrement ou d'un média au format hérité, pour que
 * les deux faces vidéo n'aient **qu'un seul chemin** à connaître.
 *
 * Volontairement séparé de [NativeCamera] et de [NativeMedia] : il ne touche
 * pas au matériel et ne doit partager ni leur cycle de vie ni leurs verrous.
 */
@UnstableApi
class NativePlayer(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/player")
    private val players = mutableMapOf<Long, Instance>()

    /** L'ouverture d'un média distant touche le réseau : jamais sur le fil principal. */
    private val worker = java.util.concurrent.Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "create") {
            create(call, result)
            return
        }

        // Toutes les autres méthodes visent un lecteur existant.
        val id = (call.argument<Any>("id") as? Number)?.toLong()
        val player = players[id]
        if (player == null) {
            // Un appel sur un lecteur déjà jeté n'est pas une anomalie : l'écran
            // peut se fermer pendant qu'une commande est en vol.
            result.success(null)
            return
        }

        when (call.method) {
            "play" -> player.play()
            "pause" -> player.pause()
            "seekTo" -> player.seekTo((call.argument<Any>("position") as? Number)?.toLong() ?: 0L)
            "setLooping" -> player.setLooping(call.argument<Boolean>("value") ?: false)
            "setVolume" -> player.setVolume((call.argument<Any>("value") as? Number)?.toFloat() ?: 1f)
            "dispose" -> {
                players.remove(id)
                player.dispose()
            }
            else -> {
                result.notImplemented()
                return
            }
        }
        result.success(null)
    }

    private fun create(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        val url = call.argument<String>("url")
        val cachePath = call.argument<String>("cachePath")
        val path = call.argument<String>("path")

        // Deux façons d'ouvrir : un fichier déjà là, ou une URL dont on ne
        // téléchargera que les blocs regardés.
        val source: () -> SealedChunkReader
        if (url != null && cachePath != null && key != null) {
            source = {
                SealedChunkReader(
                    RemoteChunkStore(
                        File(cachePath),
                        File("$cachePath.map"),
                        HttpRangeFetcher(url),
                    ),
                    key,
                )
            }
        } else if (path != null) {
            val file = File(path)
            if (!file.exists()) {
                result.error("NOT_FOUND", "média introuvable : $path", null)
                return
            }
            if (key == null) {
                // Fichier déjà en clair (Enregistrement, format hérité) : rien
                // à déchiffrer, ExoPlayer l'ouvre directement.
                startClear(file, result)
                return
            }
            source = { SealedChunkReader(file, key) }
        } else {
            result.error("BAD_ARGS", "il faut soit path, soit url + cachePath + key", null)
            return
        }

        // Le média est ouvert UNE FOIS avant d'engager le lecteur : c'est ce
        // qui permet de répondre « ce n'est pas du NVC1 » au lieu de laisser
        // une vidéo échouer plus tard sans explication. Pour une source
        // distante, cette ouverture est aussi l'amorçage — l'en-tête et le
        // premier bloc atterrissent dans le cache partiel et ne seront pas
        // redemandés.
        worker.execute {
            // L'ouverture de sonde renseigne aussi ce que l'appareil possédait
            // AVANT : c'est le seul instant où l'information existe, et le Dart
            // ne peut pas la deviner (voir [SealedChunkStore.availability]).
            var availability = SealedChunkStore.COMPLETE
            // Ce que coûte l'ouverture elle-même : entrée/sortie fichier,
            // en-tête, et — sur un média froid — l'amorçage réseau. Mesuré
            // séparément de la construction du lecteur, sinon les deux se
            // confondent dans le jalon « lecteur prêt » et on ne sait pas
            // lequel des deux corriger.
            val openStart = System.nanoTime()
            val failure = try {
                source().use {
                    it.plainLength
                    availability = it.availability
                }
                null
            } catch (e: Exception) {
                e
            }
            val openMs = (System.nanoTime() - openStart) / 1_000_000
            main.post {
                if (failure != null) {
                    // Un média au format HÉRITÉ n'a pas la magie `NVC1` : le
                    // Dart doit pouvoir le reconnaître pour retomber sur son
                    // chemin.
                    val legacy = failure.message?.contains("NVC1") == true
                    result.error(
                        if (legacy) "NOT_SEALED" else "OPEN_FAILED",
                        failure.message ?: failure.javaClass.simpleName,
                        null,
                    )
                    return@post
                }
                try {
                    val instance = Instance(sealed = source)
                    players[instance.id] = instance
                    result.success(describe(instance.id, availability, openMs))
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun startClear(file: File, result: MethodChannel.Result) {
        try {
            val instance = Instance(clear = file)
            players[instance.id] = instance
            // Un fichier en clair est sur l'appareil par définition : rien à
            // aller chercher.
            result.success(describe(instance.id, SealedChunkStore.COMPLETE, 0))
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /**
     * Ce que `create` rend au Dart.
     *
     * Un identifiant seul suffisait jusqu'au 2026-08-13 ; il manquait alors
     * l'information qui rend la mesure d'ouverture lisible. Tout naît au même
     * instant — celui de la sonde — et repart ensemble.
     */
    private fun describe(id: Long, availability: String, openMs: Long): Map<String, Any> =
        mapOf("id" to id, "availability" to availability, "openMs" to openMs)

    /** Ferme tout : appelé quand l'activité s'en va, sans quoi les lecteurs fuient. */
    fun dispose() {
        players.values.forEach { it.dispose() }
        players.clear()
        channel.setMethodCallHandler(null)
    }

    // ------------------------------------------------------------------
    // Un lecteur
    // ------------------------------------------------------------------

    private inner class Instance(
        private val clear: File? = null,
        private val sealed: (() -> SealedChunkReader)? = null,
    ) : TextureRegistry.SurfaceProducer.Callback {

        // ⚠️ **Première** propriété : en Kotlin elles s'initialisent dans
        // l'ordre du texte, et celle-ci sert d'origine des temps à tout ce qui
        // suit — à commencer par la construction de l'ExoPlayer lui-même.
        private val createdAt = System.nanoTime()

        /** Fin du bloc `init`, c'est-à-dire `prepare()` rendu. */
        private var preparedAt = 0L

        private val producer: TextureRegistry.SurfaceProducer =
            textureRegistry.createSurfaceProducer()

        val id: Long = producer.id()

        private val events = QueuingEventSink()
        private val eventChannel = EventChannel(messenger, "neovibe/player/events/$id")
        private val handler = Handler(Looper.getMainLooper())

        /** Nul si le média est déjà en clair (Enregistrement, format hérité). */
        private val factory: SealedDataSource.Factory? =
            sealed?.let { SealedDataSource.Factory(it) }

        private val exoPlayer: ExoPlayer = ExoPlayer.Builder(context).build()

        /** L'événement « prêt » ne part qu'une fois, même si le lecteur repasse par READY. */
        private var initialized = false

        /** Vrai quand ExoPlayer n'a pas de surface : ne pas lui en redemander une. */
        private var needsSurface = false

        private val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_BUFFERING ->
                        events.send(mapOf("event" to "buffering", "value" to true))
                    Player.STATE_READY -> {
                        events.send(mapOf("event" to "buffering", "value" to false))
                        sendInitialized()
                    }
                    Player.STATE_ENDED -> {
                        sendPosition()
                        events.send(mapOf("event" to "completed"))
                    }
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                events.send(mapOf("event" to "playing", "value" to isPlaying))
                if (isPlaying) startTicking() else stopTicking()
                sendPosition()
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                sendInitialized()
            }

            override fun onRenderedFirstFrame() {
                // Le seul instant qui compte pour juger « instantané » : ce que
                // l'œil voit. « Prêt » le précède parfois de plusieurs dizaines
                // de millisecondes — les confondre flatterait la mesure.
                events.send(mapOf("event" to "firstFrame"))
            }

            override fun onPlayerError(error: PlaybackException) {
                stopTicking()
                // Un échec DOIT se voir : un chargement sans fin est pire qu'une
                // erreur (leçon du 2026-08-12, troisième exemplaire).
                events.send(
                    mapOf(
                        "event" to "error",
                        "message" to (error.message ?: error.errorCodeName),
                    ),
                )
            }
        }

        /**
         * ExoPlayer ne notifie pas l'avancée du temps : elle se lit. Un battement
         * de 100 ms suffit à une barre de progression, et coûte six fois moins
         * qu'un rafraîchissement à chaque image.
         */
        private val ticker = object : Runnable {
            override fun run() {
                sendPosition()
                handler.postDelayed(this, TICK_MS)
            }
        }

        init {
            eventChannel.setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                        // Le Dart s'abonne APRÈS la création : sans file d'attente,
                        // l'événement « prêt » d'une vidéo déjà en cache partirait
                        // dans le vide et l'écran resterait sur son indicateur de
                        // chargement — la panne du 2026-08-12, en invisible.
                        events.attach(sink)
                    }

                    override fun onCancel(arguments: Any?) = events.detach()
                },
            )

            producer.setCallback(this)
            exoPlayer.setVideoSurface(producer.surface)
            needsSurface = producer.surface == null

            exoPlayer.addListener(listener)
            exoPlayer.setMediaSource(mediaSource())
            exoPlayer.prepare()
            preparedAt = System.nanoTime()
        }

        private fun mediaSource(): MediaSource {
            val sealedFactory = factory
            return if (sealedFactory != null) {
                ProgressiveMediaSource.Factory(sealedFactory)
                    .createMediaSource(MediaItem.fromUri(SealedDataSource.URI))
            } else {
                ProgressiveMediaSource.Factory(DefaultDataSource.Factory(context))
                    .createMediaSource(MediaItem.fromUri(Uri.fromFile(clear!!)))
            }
        }

        private fun sendInitialized() {
            val size = exoPlayer.videoSize
            val duration = exoPlayer.duration
            if (initialized || size.width == 0 || duration == C.TIME_UNSET) return
            initialized = true
            // Quand la texture ne redresse pas l'image elle-même, c'est à
            // l'affichage de le faire : on remonte la correction au lieu de la
            // deviner côté Dart.
            val rotation = if (producer.handlesCropAndRotation()) {
                0
            } else {
                exoPlayer.videoFormat?.rotationDegrees ?: 0
            }
            events.send(
                mapOf(
                    "event" to "initialized",
                    "width" to size.width,
                    "height" to size.height,
                    "duration" to duration,
                    "rotation" to rotation,
                    // Les deux moitiés du jalon « lecteur prêt », mesurées à
                    // part parce qu'elles ne se corrigent pas du tout de la
                    // même façon : « construction » est le prix d'un lecteur
                    // NEUF (ExoPlayer, surface, et surtout l'instanciation du
                    // décodeur matériel) — il se supprime en réutilisant ou en
                    // préparant un lecteur d'avance. « décodage » est le temps
                    // que met le média à livrer sa taille et sa durée — il
                    // dépend du fichier et de l'arrivée de ses octets.
                    "buildMs" to (preparedAt - createdAt) / 1_000_000,
                    "decodeMs" to (System.nanoTime() - preparedAt) / 1_000_000,
                ),
            )
        }

        private fun startTicking() {
            handler.removeCallbacks(ticker)
            handler.postDelayed(ticker, TICK_MS)
        }

        private fun stopTicking() = handler.removeCallbacks(ticker)

        private fun sendPosition() = events.send(
            mapOf(
                "event" to "position",
                "position" to exoPlayer.currentPosition,
                "buffered" to exoPlayer.bufferedPosition,
            ),
        )

        // --- Commandes --------------------------------------------------

        fun play() = exoPlayer.play()

        fun pause() = exoPlayer.pause()

        fun seekTo(positionMs: Long) {
            exoPlayer.seekTo(positionMs)
            sendPosition()
        }

        fun setLooping(value: Boolean) {
            exoPlayer.repeatMode = if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
        }

        fun setVolume(value: Float) {
            exoPlayer.volume = value.coerceIn(0f, 1f)
        }

        // --- Cycle de vie de la surface ---------------------------------

        override fun onSurfaceAvailable() {
            if (needsSurface) {
                exoPlayer.setVideoSurface(producer.surface)
                needsSurface = false
            }
        }

        override fun onSurfaceCleanup() {
            exoPlayer.setVideoSurface(null)
            needsSurface = true
        }

        fun dispose() {
            stopTicking()
            exoPlayer.removeListener(listener)
            // Le lecteur d'abord, la surface ensuite : l'inverse laisserait
            // ExoPlayer dessiner dans une surface déjà rendue.
            exoPlayer.release()
            producer.release()
            // Ferme les descripteurs de fichier des sources scellées : ExoPlayer
            // en crée une par déplacement dans la vidéo.
            factory?.releaseAll()
            eventChannel.setStreamHandler(null)
            events.detach()
        }
    }

    private companion object {
        const val TICK_MS = 100L
    }
}

/**
 * Garde les événements émis avant que le Dart ne s'abonne.
 *
 * Sans ça, une vidéo déjà en cache — prête en quelques millisecondes — enverrait
 * son « prêt » dans le vide, et l'écran resterait sur son indicateur de
 * chargement pour toujours.
 */
private class QueuingEventSink {
    private val pending = mutableListOf<Map<String, Any?>>()
    private var sink: EventChannel.EventSink? = null

    fun attach(sink: EventChannel.EventSink?) {
        this.sink = sink
        if (sink != null) {
            pending.forEach { sink.success(it) }
            pending.clear()
        }
    }

    fun detach() {
        sink = null
    }

    fun send(event: Map<String, Any?>) {
        val current = sink
        if (current == null) pending.add(event) else current.success(event)
    }
}
