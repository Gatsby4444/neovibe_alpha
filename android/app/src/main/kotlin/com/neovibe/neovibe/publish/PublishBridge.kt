package com.neovibe.neovibe.publish

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * **Le pont entre l'app et la file de publication** (`neovibe/publish`).
 *
 * Il est jetable : il naît et meurt avec l'activité, alors que le service et
 * les fichiers, eux, survivent — même dessin que `ProximityBridge`.
 *
 * | méthode | ce qu'elle fait |
 * |---|---|
 * | `configure` | dépose la session (url, clé publique, jeton) — à chaque connexion et renouvellement |
 * | `jobDir` | le dossier de travail d'une publication, où le Dart rend ses photos |
 * | `enqueue` | dépose une publication (le JSON de [PublishJob]) et réveille le service |
 * | `release` | « Publier » : la légende et les droits ; le service inscrit quand tout est déposé |
 * | `cancel` | l'utilisateur est revenu en arrière : le travail s'arrête, le dossier s'efface |
 * | `retry` | après un échec : on repart de ce qui est fait |
 * | `ack` | l'app a vu la publication dans sa liste : le dossier s'efface |
 * | `pending` | l'état de tout ce qui est rangé (au démarrage de l'écran) |
 *
 * Les changements arrivent par le canal d'événements `neovibe/publish/events`
 * (la liste des instantanés) ; `needToken` y passe aussi, sous la forme
 * `{"needToken": true}`.
 */
class PublishBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, PublishHub.Listener {

    private val channel = MethodChannel(messenger, "neovibe/publish")
    private val events = EventChannel(messenger, "neovibe/publish/events")
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val store = PublishStore(context)
    private val sessions = SessionStore(context)
    private var sink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        PublishHub.add(this)
    }

    fun dispose() {
        PublishHub.remove(this)
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                val url = call.argument<String>("url")
                val anon = call.argument<String>("anonKey")
                val token = call.argument<String>("accessToken")
                if (url == null || anon == null || token == null) {
                    result.error("BAD_ARGS", "url, anonKey et accessToken sont requis", null)
                    return
                }
                io.execute {
                    sessions.write(Session(url, anon, token))
                    if (store.active().isNotEmpty()) PublishService.kick(context)
                    main.post { result.success(null) }
                }
            }
            "signOut" -> io.execute {
                sessions.clear()
                main.post { result.success(null) }
            }
            "jobDir" -> {
                val id = call.argument<String>("id") ?: return result.error("BAD_ARGS", "id requis", null)
                result.success(store.dir(id).path)
            }
            "enqueue" -> {
                val json = call.argument<String>("job") ?: return result.error("BAD_ARGS", "job requis", null)
                io.execute {
                    val outcome = runCatching {
                        val job = PublishJob.fromJson(json)
                        store.save(job)
                        PublishService.kick(context)
                        snapshot()
                    }
                    main.post {
                        outcome.onSuccess { result.success(null) }
                            .onFailure { result.error("BAD_JOB", it.message, null) }
                    }
                }
            }
            "release" -> {
                val id = call.argument<String>("id") ?: return result.error("BAD_ARGS", "id requis", null)
                io.execute {
                    store.saveRelease(
                        id,
                        Release(
                            caption = call.argument<String>("caption"),
                            captionFont = call.argument<String>("captionFont"),
                            isPublic = call.argument<Boolean>("isPublic") ?: false,
                            shareable = call.argument<Boolean>("shareable") ?: false,
                            saveable = call.argument<Boolean>("saveable") ?: false,
                        ),
                    )
                    PublishService.kick(context)
                    snapshot()
                    main.post { result.success(null) }
                }
            }
            "cancel" -> {
                val id = call.argument<String>("id") ?: return result.error("BAD_ARGS", "id requis", null)
                io.execute {
                    val job = store.load(id)
                    if (job != null && job.isActive) {
                        store.markCancelled(id)
                        // Le service la voit et fait le ménage ; s'il ne tourne
                        // pas (rien n'avait commencé), on efface nous-mêmes.
                        PublishService.kick(context)
                    } else if (job != null) {
                        store.delete(id)
                    }
                    snapshot()
                    main.post { result.success(null) }
                }
            }
            "retry" -> {
                val id = call.argument<String>("id") ?: return result.error("BAD_ARGS", "id requis", null)
                io.execute {
                    val job = store.load(id)
                    if (job != null && job.phase == PublishJob.FAILED) {
                        // On repart de ce qui est fait : un fichier scellé et
                        // déposé ne l'est pas deux fois.
                        job.phase = when {
                            job.files.all { it.uploaded } -> PublishJob.REGISTERING
                            job.media.all { it.transcoded } && job.files.all { it.isSealed } -> PublishJob.UPLOADING
                            else -> PublishJob.PREPARING
                        }
                        job.error = null
                        job.attempts = 0
                        store.save(job)
                        PublishService.kick(context)
                    }
                    snapshot()
                    main.post { result.success(null) }
                }
            }
            "ack" -> {
                val id = call.argument<String>("id") ?: return result.error("BAD_ARGS", "id requis", null)
                io.execute {
                    val job = store.load(id)
                    if (job != null && !job.isActive) store.delete(id)
                    snapshot()
                    main.post { result.success(null) }
                }
            }
            "pending" -> io.execute {
                val list = current()
                main.post { result.success(list) }
            }
            else -> result.notImplemented()
        }
    }

    private fun current(): List<Map<String, Any?>> =
        store.all().map { it.snapshot(store.release(it.id) != null) }

    /** Republie l'état après une écriture du pont (le service n'est peut-être pas là). */
    private fun snapshot() = PublishHub.snapshot(current())

    // ------------------------------------------------------------------
    // Événements vers le Dart
    // ------------------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
        io.execute {
            val list = current()
            main.post { this.sink?.success(mapOf("jobs" to list)) }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onSnapshot(jobs: List<Map<String, Any?>>) {
        main.post { sink?.success(mapOf("jobs" to jobs)) }
    }

    override fun onNeedToken() {
        main.post { sink?.success(mapOf("needToken" to true)) }
    }
}
