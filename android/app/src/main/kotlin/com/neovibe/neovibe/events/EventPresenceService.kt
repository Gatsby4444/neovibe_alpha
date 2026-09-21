package com.neovibe.neovibe.events

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.neovibe.neovibe.MainActivity
import com.neovibe.neovibe.publish.AuthExpired
import com.neovibe.neovibe.publish.Rejected
import com.neovibe.neovibe.publish.SessionStore
import com.neovibe.neovibe.publish.SupabaseHttp
import java.io.IOException
import java.util.concurrent.Executors

/**
 * **Ma présence à un événement, app fermée** — le prérequis §0 du programme
 * du 2026-09-21 (Jay : « la position en arrière-plan »).
 *
 * ## Ce qu'il fait, en une phrase
 *
 * Tant que je suis dans un événement, il relève ma position **une fois par
 * minute** et la dépose au serveur (`report_event_position`), écran éteint,
 * app fermée. C'est tout. Il ne décide ni si je suis loin ni si je suis
 * sorti : le serveur compare aux points chauds et répond `present`, `away`
 * ou `none` — et sur `away` / `none`, le service s'arrête.
 *
 * ## Pourquoi un service de premier plan de type `location`, sans
 * « Autoriser tout le temps »
 *
 * Un service de premier plan de type `location` fait compter l'app comme
 * « au premier plan » pour la localisation : `ACCESS_FINE_LOCATION` en
 * « pendant l'utilisation » suffit alors, interface fermée (le raisonnement
 * de `ProximityService`, constaté le 2026-08-25). La seule condition est de
 * le DÉMARRER depuis l'interface — ce qui est toujours le cas : on rejoint
 * un événement dans l'app.
 *
 * ## Un seul relevé, une seule écriture
 *
 * Depuis le 2026-09-21 **c'est ici, et seulement ici**, que la position
 * d'événement se dépose — au premier plan aussi. Le Dart démarre et arrête
 * ce service, et lit ce qu'il constate ([EventPresenceHub]) ; il ne relève
 * plus rien lui-même. Un chemin, une donnée.
 *
 * ## Ce qu'il ne fait pas
 *
 * Il ne renouvelle pas le jeton : quand le serveur le refuse, il s'arrête
 * (le BLE, l'autre preuve du système mixte, continue de tenir la présence
 * via `report_sightings`), et l'app le relance à son retour avec une
 * session fraîche.
 */
class EventPresenceService : Service() {

    private val sessions by lazy { SessionStore(this) }
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var eventId: String? = null
    private var title: String = "Événement"
    private var last: Location? = null
    private var listening = false

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val prev = last
            // Le meilleur des deux fournisseurs : le plus précis s'il est
            // récent, sinon le plus récent.
            last = if (prev == null || location.accuracy <= prev.accuracy ||
                location.time - prev.time > 30_000L) location else prev
        }

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val tick = object : Runnable {
        override fun run() {
            report()
            main.postDelayed(this, EVERY_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannel()
        startForeground(NOTIFICATION_ID, notification("Présence en cours…"), TYPE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra(EXTRA_EVENT)
        if (id == null) {
            // Relancé par Android sans intention (START_STICKY) : sans
            // événement connu, rien à faire — on s'efface.
            stopSelf()
            return START_NOT_STICKY
        }
        eventId = id
        title = intent.getStringExtra(EXTRA_TITLE) ?: title
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification("Présent à $title"))
        startListening()
        main.removeCallbacks(tick)
        main.post(tick)
        return START_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacks(tick)
        stopListening()
        worker.shutdownNow()
        if (instance === this) instance = null
        EventPresenceHub.snapshot(eventId, "stopped")
        super.onDestroy()
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun startListening() {
        if (listening || !hasPermission()) return
        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            runCatching {
                if (lm.isProviderEnabled(provider)) {
                    lm.requestLocationUpdates(provider, EVERY_MS / 2, 0f, listener, Looper.getMainLooper())
                    lm.getLastKnownLocation(provider)?.let { listener.onLocationChanged(it) }
                }
            }
        }
        listening = true
    }

    private fun stopListening() {
        if (!listening) return
        runCatching {
            (getSystemService(Context.LOCATION_SERVICE) as LocationManager).removeUpdates(listener)
        }
        listening = false
    }

    /** Dépose la dernière position ; ce que le serveur répond décide de la suite. */
    private fun report() {
        val fix = last
        val id = eventId ?: return
        if (fix == null || System.currentTimeMillis() - fix.time > STALE_MS) {
            EventPresenceHub.snapshot(id, "no_fix")
            return
        }
        val session = sessions.read()
        if (session == null) {
            EventPresenceHub.snapshot(id, "no_session")
            stopSelf()
            return
        }
        worker.execute {
            val outcome = try {
                val body = "{\"p_lat\":${fix.latitude},\"p_lon\":${fix.longitude},\"p_acc\":${fix.accuracy}}"
                SupabaseHttp(session).rpcText("report_event_position", body).trim('"', ' ', '\n')
            } catch (e: AuthExpired) {
                "auth"
            } catch (e: Rejected) {
                "rejected"
            } catch (e: IOException) {
                "offline"
            } catch (e: Exception) {
                "error"
            }
            EventPresenceHub.snapshot(id, outcome)
            // `away` : le serveur m'a sorti ; `none` : je ne suis plus dans
            // aucun événement ; `auth` : l'app relancera avec un jeton frais.
            if (outcome == "away" || outcome == "none" || outcome == "auth" || outcome == "rejected") {
                main.post { stopSelf() }
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Présence à un événement", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Ta présence à l'événement que tu as rejoint"
                setShowBadge(false)
            },
        )
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("NeoVibe")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
    }

    companion object {
        const val EVERY_MS = 60_000L
        /** Une position de plus de 5 min n'est pas « là où je suis ». */
        const val STALE_MS = 5 * 60_000L
        private const val CHANNEL_ID = "neovibe_event_presence"
        private const val NOTIFICATION_ID = 2101
        private const val EXTRA_EVENT = "event"
        private const val EXTRA_TITLE = "title"
        const val TYPE = ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION

        @Volatile
        private var instance: EventPresenceService? = null

        val running: Boolean get() = instance != null

        /** Démarre (ou re-cible) le service — toujours depuis l'interface. */
        fun start(context: Context, eventId: String, title: String) {
            val intent = Intent(context, EventPresenceService::class.java)
                .putExtra(EXTRA_EVENT, eventId)
                .putExtra(EXTRA_TITLE, title)
            runCatching { context.startForegroundService(intent) }
        }

        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, EventPresenceService::class.java)) }
        }
    }
}

/**
 * Ce que le service constate, publié vers le pont (s'il est là) — pour
 * l'écran, jamais pour décider.
 */
object EventPresenceHub {
    interface Listener {
        fun onPresence(eventId: String?, outcome: String)
    }

    private val listeners = mutableSetOf<Listener>()

    @Synchronized
    fun add(l: Listener) { listeners.add(l) }

    @Synchronized
    fun remove(l: Listener) { listeners.remove(l) }

    @Synchronized
    fun snapshot(eventId: String?, outcome: String) {
        for (l in listeners.toList()) l.onPresence(eventId, outcome)
    }
}
