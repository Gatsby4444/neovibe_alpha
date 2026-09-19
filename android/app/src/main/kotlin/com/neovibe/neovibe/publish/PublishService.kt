package com.neovibe.neovibe.publish

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.neovibe.neovibe.MainActivity
import com.neovibe.neovibe.MediaTranscoder
import com.neovibe.neovibe.NativeMedia
import com.neovibe.neovibe.SealedChunkWriter
import java.io.File
import java.util.concurrent.Executors

/**
 * **Le service qui publie** — la file native et persistante tranchée par Jay
 * le 2026-09-19 : *« la publication est une file NATIVE et persistante »*.
 *
 * Il ne fait qu'une chose : tant qu'il reste une publication à faire
 * avancer, il la fait avancer ([PublishPipeline]), et il le dit dans sa
 * notification. Quand il n'y a plus rien, il s'arrête tout seul.
 *
 * ## Ce qui le réveille
 *
 * - l'app, à chaque dépôt, « Publier », annulation, réessai, ou jeton frais
 *   ([kick]) ;
 * - le retour du réseau (un rappel de `ConnectivityManager`) ;
 * - Android, s'il l'a tué (`START_STICKY`) ou après un redémarrage
 *   ([BootReceiver]) : il relit le disque et reprend.
 *
 * ## Ce qu'il ne fait pas
 *
 * Il ne renouvelle pas le jeton (voir [SessionStore]) : quand le serveur le
 * refuse, il demande à l'app et attend. Il ne rend pas de photo : le rendu
 * d'une photo passe par le shader de l'aperçu, en Dart, à « Suivant ».
 *
 * Service de premier plan de type `dataSync` : c'est le type prévu pour un
 * envoi qui doit finir même si l'utilisateur quitte l'app ; Android 15 le
 * borne à six heures par jour, très au-delà d'une publication.
 */
class PublishService : Service() {

    private val store by lazy { PublishStore(this) }
    private val sessions by lazy { SessionStore(this) }
    private val worker = Executors.newSingleThreadExecutor()
    private val uploads = Executors.newFixedThreadPool(2)
    private val lock = Object()

    @Volatile
    private var looping = false

    @Volatile
    private var poked = false

    private var network: ConnectivityManager.NetworkCallback? = null

    private val tools = object : MediaTools {
        override fun transcode(
            spec: TranscodeSpec,
            source: File,
            dest: File,
            onProgress: (Float) -> Unit,
            isCancelled: () -> Boolean,
        ): Int {
            val p = MediaTranscoder.Params(
                source = source,
                dest = dest,
                startMs = spec.startMs,
                endMs = spec.endMs,
                corners = FloatArray(8) { spec.corners[it] },
                outWidth = spec.outWidth,
                outHeight = spec.outHeight,
                uniforms = FloatArray(24) { spec.uniforms[it] },
                overlayPath = spec.overlayPath,
                rotation = spec.rotation,
            )
            val r = MediaTranscoder.run(p, onProgress, isCancelled)
            if (!r.ok) throw IllegalStateException("${r.message}${if (r.note.isNotEmpty()) " · ${r.note}" else ""}")
            return r.durationMs
        }

        override fun poster(source: File, dest: File, width: Int, atMs: Int): String? =
            NativeMedia.extract(source.path, dest.path, width, atMs)

        override fun seal(source: File, dest: File, keyBase64: String) =
            SealedChunkWriter.seal(source, dest, keyBase64)
    }

    private val pipeline by lazy {
        PublishPipeline(
            store = store,
            session = { sessions.read() },
            remote = { SupabaseHttp(it) },
            tools = tools,
            uploads = uploads,
            onChange = { publish() },
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannel()
        startForeground(NOTIFICATION_ID, notification("Publication en cours…", null), TYPE)
        watchNetwork()
        // Une publication finie que l'app n'a pas acquittée en un jour : l'app
        // n'est pas revenue ; son `job.json` ne sert plus à personne.
        val limit = System.currentTimeMillis() - 24 * 3600_000L
        for (j in store.all()) if (!j.isActive && j.createdAt < limit) store.delete(j.id)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Relancé par Android sans intention : on repart du disque.
        startForeground(NOTIFICATION_ID, notification("Publication en cours…", null), TYPE)
        poke()
        return START_STICKY
    }

    override fun onDestroy() {
        network?.let { runCatching { connectivity().unregisterNetworkCallback(it) } }
        worker.shutdownNow()
        uploads.shutdownNow()
        if (instance === this) instance = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // La boucle
    // ------------------------------------------------------------------

    /** Quelque chose a changé (dépôt, jeton, réseau) : la boucle repasse. */
    fun poke() {
        synchronized(lock) {
            poked = true
            lock.notifyAll()
            if (!looping) {
                looping = true
                worker.execute { loop() }
            }
        }
    }

    private fun loop() {
        try {
            while (true) {
                synchronized(lock) { poked = false }
                val jobs = store.active()
                if (jobs.isEmpty()) break
                var shortest = Long.MAX_VALUE
                var needToken = false
                for (job in jobs) {
                    when (val w = pipeline.process(job)) {
                        is Wait.None -> {}
                        is Wait.Release -> {}
                        is Wait.Token -> needToken = true
                        is Wait.Backoff -> shortest = minOf(shortest, w.delayMs)
                    }
                }
                publish()
                if (store.active().isEmpty()) break
                if (needToken) {
                    PublishHub.needToken()
                    shortest = minOf(shortest, 60_000L)
                }
                synchronized(lock) {
                    if (!poked) {
                        if (shortest == Long.MAX_VALUE) lock.wait() else lock.wait(shortest)
                    }
                }
            }
        } catch (_: InterruptedException) {
        } finally {
            synchronized(lock) { looping = false }
            publish()
            if (store.active().isEmpty()) {
                val failed = store.all().filter { it.phase == PublishJob.FAILED }
                if (failed.isNotEmpty()) {
                    notify("Publication échouée", failed.first().error ?: "ouvre NeoVibe pour réessayer")
                }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    /** L'état de tout ce qui est rangé, vers l'app et vers la notification. */
    private fun publish() {
        val all = store.all()
        val released = all.associate { it.id to (store.release(it.id) != null) }
        PublishHub.snapshot(all.map { it.snapshot(released[it.id] == true) })
        val active = all.filter { it.isActive && released[it.id] == true }
        if (active.isNotEmpty()) {
            val j = active.first()
            val pct = (j.progress * 100).toInt()
            val text = when (j.phase) {
                PublishJob.PREPARING -> "Préparation… $pct %"
                PublishJob.UPLOADING -> "Envoi… $pct %"
                PublishJob.REGISTERING -> "Presque fini…"
                else -> "En cours…"
            } + if (active.size > 1) " · ${active.size - 1} en attente" else ""
            val manager = getSystemService(NotificationManager::class.java)
            manager?.notify(NOTIFICATION_ID, notification(text, if (j.phase == PublishJob.REGISTERING) null else pct))
        }
    }

    // ------------------------------------------------------------------
    // Réseau
    // ------------------------------------------------------------------

    private fun connectivity() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private fun watchNetwork() {
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = poke()
        }
        runCatching { connectivity().registerDefaultNetworkCallback(cb) }.onSuccess { network = cb }
    }

    // ------------------------------------------------------------------
    // Notification
    // ------------------------------------------------------------------

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Publications", NotificationManager.IMPORTANCE_LOW).apply {
                description = "L'envoi de tes publications"
                setShowBadge(false)
            },
        )
    }

    private fun notification(text: String, percent: Int?): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("NeoVibe")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .apply { if (percent != null) setProgress(100, percent, false) else setProgress(0, 0, true) }
            .build()
    }

    private fun notify(title: String, text: String) {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        getSystemService(NotificationManager::class.java)?.notify(FAILED_ID, n)
    }

    companion object {
        private const val CHANNEL_ID = "neovibe_publish"
        private const val NOTIFICATION_ID = 2001
        private const val FAILED_ID = 2002

        @Volatile
        private var instance: PublishService? = null

        /**
         * Réveille le service — le démarre s'il ne tourne pas. Depuis
         * l'arrière-plan, Android 12+ peut refuser le démarrage : on ne lève
         * pas, la publication attendra le prochain passage au premier plan.
         */
        fun kick(context: Context) {
            instance?.let {
                it.poke()
                return
            }
            runCatching {
                context.startForegroundService(Intent(context, PublishService::class.java))
            }
        }

        /** Le type déclaré au manifeste, redit à `startForeground`. */
        const val TYPE = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    }
}
