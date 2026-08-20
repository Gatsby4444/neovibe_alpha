package com.neovibe.neovibe.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Le point de rendez-vous entre le pont et le service.
 *
 * ## Pourquoi il existe — le défaut du 2026-08-16, relevé par Jay au test
 *
 * Le pont s'enregistrait auprès du service par `ProximityService.instance?.bridge = this`,
 * **au moment où le Dart s'abonne au flux**. Or, à cet instant, le service
 * n'existe pas encore : il ne démarre qu'à l'appel de `start`, plus tard. Le
 * `?.` avalait donc l'affectation **en silence**, et le service tournait ensuite
 * pour toujours sans destinataire.
 *
 * Symptômes, tous expliqués par cette seule ligne : la notification disait vrai
 * (le moteur, lui, savait), l'écran restait bloqué sur « Démarrage… » (aucun
 * état ne remontait), et rien n'était jamais détecté (aucun scan ne remontait
 * non plus).
 *
 * ⚠️ **La leçon dépasse le correctif** : deux objets dont l'un doit trouver
 * l'autre ne doivent pas dépendre de **l'ordre dans lequel ils naissent**. Ici,
 * chacun dépose et lit au même endroit ; quel que soit le premier arrivé, le
 * lien se fait. C'est la cause supprimée, pas une initialisation mieux rangée.
 */
object ProximityBus {
    @Volatile
    var listener: BleEngine.Listener? = null
}

/**
 * Le service de premier plan qui POSSÈDE la radio.
 *
 * ## Pourquoi un service, et pas l'activité
 *
 * Décision de Jay, 2026-08-16 : *« natif Kotlin, service dédié »*. Android
 * détruit une activité dès qu'il en a envie — mise en veille, changement
 * d'application, manque de mémoire. Tant que la radio appartenait à l'activité,
 * la détection s'arrêtait avec elle, **sans que rien ne le signale**.
 *
 * Ici, [BleEngine] appartient au service. L'interface peut disparaître : le scan
 * continue, l'advertising continue, et l'état reste vrai.
 *
 * ⚠️ **Ce que ce service ne fait PAS, et qu'il ne faut pas croire acquis** : il
 * ne déchiffre rien et ne répond à aucune poignée de main. Le protocole vit en
 * Dart. Quand l'interface est absente, la radio continue de **voir** et de
 * **retenir** (voir [pendingScans]), mais une révélation d'inconnu, elle,
 * attendra le retour du Dart. Étendre le protocole au natif est un chantier en
 * soi, et il n'aurait de toute façon pas d'équivalent iOS.
 */
class ProximityService : Service(), BleEngine.Listener {

    companion object {
        private const val CHANNEL_ID = "neovibe_proximity"
        private const val NOTIFICATION_ID = 4201

        const val ACTION_START = "com.neovibe.proximity.START"
        const val ACTION_STOP = "com.neovibe.proximity.STOP"
        const val EXTRA_ADVERT_ID = "advertId"

        /**
         * L'instance vivante, si le service tourne.
         *
         * Même processus des deux côtés : un binder n'apporterait rien qu'une
         * indirection. Ce qui compte est que le pont Dart soit **remplaçable à
         * chaud** — l'interface peut mourir et renaître plusieurs fois pendant
         * la vie du service.
         */
        @Volatile
        var instance: ProximityService? = null
            private set

        fun start(context: Context, advertId: ByteArray) {
            val intent = Intent(context, ProximityService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ADVERT_ID, advertId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ProximityService::class.java).apply { action = ACTION_STOP },
            )
        }
    }

    /** Le pont vers le Dart, quand il y en a un. Publié par [ProximityBus]. */
    private val bridge: BleEngine.Listener? get() = ProximityBus.listener

    private lateinit var engine: BleEngine
    private var lastStatus: RadioStatus = RadioStatus.Idle

    /**
     * Ce que la radio a vu pendant que l'interface était absente.
     *
     * Borné à [SCAN_BUFFER_MAX] : on veut savoir *que* quelqu'un est passé, pas
     * rejouer une heure de scan. Au-delà, les plus anciennes tombent — une
     * mémoire non bornée dans un service qui vit des jours est une fuite.
     */
    private data class BufferedScan(
        val address: String,
        val advertId: ByteArray,
        val rssi: Int,
        val txPower: Int,
    )

    private val pendingScans = ConcurrentLinkedQueue<BufferedScan>()
    private val scanBufferMax = 200

    // ------------------------------------------------------------------
    // Le plan d'emission — la correction du point H
    // ------------------------------------------------------------------

    /**
     * Ce que le Dart nous a laisse a crier, et pour combien de temps.
     *
     * ⚠️ **C'est ce qui rend ce service independant du Dart.** Avant, le Dart
     * poussait un identifiant a chaque changement de creneau ; s'il mourait,
     * l'identifiant se figeait et l'appareil devenait invisible pour tous ses
     * amis sans que rien ne le signale. Ici le Dart depose des heures d'avance,
     * et nous choisissons nous-memes.
     */
    @Volatile
    private var schedule: AdvertSchedule? = null

    private var cursor = 0
    private val cycleHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * Cadence de rotation a l'interieur d'un creneau.
     *
     * Chaque changement d'annonce coute un arret/relance de l'advertising. A un
     * seul jeu d'annonces, il faut donc arbitrer entre « chaque ami me voit
     * vite » et « la radio ne passe pas son temps a redemarrer ».
     *
     * ⚠️ **Valeur RAISONNEE, pas mesuree** (2026-08-20) : le cout reel d'un
     * redemarrage d'advertising n'a pas ete releve sur appareil. A confronter au
     * terrain avant de la figer.
     */
    private val cycleMillis = 400L

    private val cycleTick = object : Runnable {
        override fun run() {
            emitNext()
            val plan = schedule
            // Un seul jeton par creneau : inutile de se reveiller souvent, il
            // suffit d'etre la au changement de creneau.
            val delay = if (plan == null || plan.cycleLength <= 1) 30_000L else cycleMillis
            cycleHandler.postDelayed(this, delay)
        }
    }

    private fun emitNext() {
        val plan = schedule ?: return
        val token = plan.tokenAt(System.currentTimeMillis(), cursor)
        if (token == null) {
            // ⚠️ **Plan epuise : on se TAIT.** Reemettre le dernier jeton connu
            // serait indiscernable d'un fonctionnement normal, alors que plus
            // personne ne nous reconnaitrait. Le silence, lui, se constate — et
            // il se dit.
            engine.pauseAdvertising()
            onStatus(
                RadioStatus.Failed(
                    "planExpired",
                    "Le plan d'emission est epuise : rouvre l'app pour le renouveler.",
                ),
            )
            return
        }
        cursor++
        engine.updateAdvert(token)
    }

    /** Le Dart depose un nouveau plan. Il remplace entierement le precedent. */
    fun setAdvertSchedule(plan: AdvertSchedule) {
        schedule = plan
        cursor = 0
        cycleHandler.removeCallbacks(cycleTick)
        if (!plan.isEmpty) {
            emitNext()
            cycleHandler.postDelayed(cycleTick, if (plan.cycleLength <= 1) 30_000L else cycleMillis)
        }
    }

    /** Jusqu'a quand le plan courant tient, pour que le Dart sache le renouveler. */
    fun scheduleValidUntil(): Long = schedule?.validUntilMillis ?: 0L

    // ------------------------------------------------------------------
    // La reconnaissance sans le Dart
    // ------------------------------------------------------------------

    @Volatile
    private var recognition: RecognitionTable? = null

    private val sightings = SightingBuffer()

    /** Duree d'un creneau, deposee avec la table. */
    @Volatile
    private var slotMillis = 900_000L

    /**
     * Le Dart depose la table de reconnaissance. Elle remplace la precedente.
     *
     * ⚠️ Elle ne contient **aucune identite** : des jetons et des rangs. Seul le
     * Dart sait a qui correspond le rang 3, et il le sait pour CETTE table —
     * d'ou le `tableId` renvoye avec chaque constat.
     */
    fun setRecognitionTable(table: RecognitionTable, slotDurationMillis: Long) {
        recognition = table
        slotMillis = slotDurationMillis
    }

    /** Rend les constats accumules et vide le tampon. */
    fun takeSightings(): List<NativeSighting> = sightings.drain()

    fun sightingCount(): Int = sightings.size

    override fun onCreate() {
        super.onCreate()
        instance = this
        engine = BleEngine(applicationContext, this)
        engine.attach()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                engine.stop()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val advertId = intent?.getByteArrayExtra(EXTRA_ADVERT_ID)
                if (advertId == null) {
                    // Android nous a relances apres nous avoir tues : l'intent
                    // d'origine est perdu, donc l'identifiant rotatif aussi. Il
                    // est derive d'une cle du Keystore que SEUL le Dart sait
                    // lire : impossible de le reconstruire ici.
                    //
                    // On ne garde donc PAS une notification qui annonce une
                    // detection qui n'existe pas. On se retire ; le superviseur
                    // Dart relancera tout au prochain lancement de l'app, en
                    // relisant l'intention persistee.
                    onStatus(
                        RadioStatus.Failed(
                            "restarted",
                            "Le service a ete relance par le systeme : rouvre " +
                                "l'app pour reprendre la detection.",
                        ),
                    )
                    stopForegroundCompat()
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForegroundCompat()
                engine.start(advertId)
            }
        }
        // START_STICKY : si Android nous tue sous la pression mémoire, il nous
        // relance. L'intention de l'utilisateur, elle, est relue côté Dart.
        return START_STICKY
    }

    override fun onDestroy() {
        // Le minuteur du plan appartient a ce service : le laisser tourner apres
        // sa mort, c'est exactement le genre de noeud orphelin que ce projet
        // passe son temps a chasser.
        cycleHandler.removeCallbacks(cycleTick)
        schedule = null
        // La table et les constats appartiennent a ce service : les laisser
        // derriere serait garder une trace de qui a ete croise, sans personne
        // pour la reclamer.
        recognition = null
        sightings.clear()
        engine.detach()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------------
    // Commandes venues du Dart
    // ------------------------------------------------------------------

    fun updateAdvert(advertId: ByteArray) = engine.updateAdvert(advertId)
    fun advertCapabilities(): Map<String, Any?> = engine.advertCapabilities()
    fun connect(address: String, done: (String?) -> Unit) = engine.connect(address, done)
    fun disconnect(linkId: String) = engine.disconnect(linkId)
    fun send(linkId: String, data: ByteArray): Boolean = engine.send(linkId, data)
    fun mtuOf(linkId: String): Int = engine.mtuOf(linkId)

    /** Ce que la radio a reellement recu depuis le dernier demarrage. */
    fun stats(): Map<String, Any?> = mapOf(
        "rawScans" to engine.rawScans,
        "neoScans" to engine.neoScans,
        "sdk" to android.os.Build.VERSION.SDK_INT,
        "device" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
        // ⚠️ **Les technologies de mesure de distance que l'appareil possede.**
        //
        // Question de Jay, 2026-08-16 : « pour la distance tu as juste utilise
        // le BLE ? ». Oui - c'est la seule radio que TOUS les appareils ont.
        // Mais deux autres donneraient bien mieux si le materiel les portait :
        // l'UWB (~10 cm) et le Wi-Fi RTT (~1-2 m).
        //
        // Plutot que de supposer d'apres le modele, on DEMANDE au systeme. Un
        // « probablement pas » sur une fiche technique ne vaut pas un
        // hasSystemFeature.
        "uwb" to packageManager.hasSystemFeature("android.hardware.uwb"),
        "wifiRtt" to packageManager.hasSystemFeature("android.hardware.wifi.rtt"),
        // ⚠️ **Les deux transports Wi-Fi, sondes ajoutees le 2026-08-17.**
        //
        // Question de Jay : « le Wi-Fi Direct on peut l'utiliser pour les
        // messages ? Peut-etre que cela sera plus fiable que le BLE ? ».
        //
        // `wifiDirect` est present a peu pres partout ; `wifiAware` beaucoup
        // moins, et c'est pourtant LUI le bon candidat (pas de formation de
        // groupe, plusieurs pairs, concu pour le voisinage). Plutot que de
        // supposer d'apres le modele, on DEMANDE au systeme - meme methode que
        // pour l'UWB, ou la supposition aurait ete fausse dans les deux sens.
        "wifiDirect" to packageManager.hasSystemFeature("android.hardware.wifi.direct"),
        "wifiAware" to packageManager.hasSystemFeature("android.hardware.wifi.aware"),
        // Les chemins physiques ouverts, par role. Voir `BleEngine.pathStats` :
        // c'est la mesure qui dira si une meme adresse porte DEUX connexions
        // GATT — hypothese des messages fantomes restants, non encore observee.
    ) + engine.pathStats

    // ------------------------------------------------------------------
    // Écoute du moteur
    // ------------------------------------------------------------------

    override fun onStatus(status: RadioStatus) {
        lastStatus = status
        bridge?.onStatus(status)
        updateNotification(status)
    }

    override fun onScan(address: String, advertId: ByteArray, rssi: Int, txPower: Int) {
        // ⚠️ **On reconnait TOUJOURS, que le Dart soit la ou non.**
        //
        // C'est le point de tout ce fichier : avant, l'appariement jeton -> ami
        // vivait en Dart, qui meurt avec l'interface. App fermee, l'appareil
        // etait donc **vu sans voir**, et le croisement — fait pour le telephone
        // dans la poche — ne se produisait jamais.
        //
        // Le faire ici ET quand le Dart est present n'est pas une redondance :
        // c'est ce qui evite d'avoir deux comportements selon que l'interface
        // est ouverte ou non. Le Dart deduplique de toute facon par
        // (ami, creneau).
        val table = recognition
        if (table != null) {
            val now = System.currentTimeMillis()
            val rang = table.match(advertId, now)
            if (rang != null) {
                sightings.note(
                    NativeSighting(
                        tableId = table.tableId,
                        friendIndex = rang,
                        slot = now / slotMillis,
                        rssi = rssi,
                        txPower = txPower,
                    ),
                )
            }
        }

        val target = bridge
        if (target != null) {
            target.onScan(address, advertId, rssi, txPower)
            return
        }
        pendingScans.add(BufferedScan(address, advertId, rssi, txPower))
        while (pendingScans.size > scanBufferMax) pendingScans.poll()
    }

    override fun onLink(linkId: String, connected: Boolean, mtu: Int, incoming: Boolean) {
        // Un lien sans Dart pour lui parler ne sert à rien : on ne le met pas en
        // attente, on le laisse tomber. Le pair réessaiera.
        bridge?.onLink(linkId, connected, mtu, incoming)
    }

    override fun onFrame(linkId: String, data: ByteArray) {
        // Idem : une trame chiffrée que personne ne peut ouvrir est perdue, et
        // c'est assumé. La rejouer plus tard casserait l'anti-rejeu du canal.
        bridge?.onFrame(linkId, data)
    }

    /**
     * Rejoue l'état courant et les scans mis de côté au pont qui vient
     * d'arriver.
     *
     * Appelé par le pont lui-même : une interface qui vient de naître n'a pas à
     * deviner ce qui s'est passé avant elle.
     */
    fun replayToBridge() {
        replayTo(ProximityBus.listener ?: return)
    }

    private fun replayTo(target: BleEngine.Listener) {
        target.onStatus(lastStatus)
        while (true) {
            val scan = pendingScans.poll() ?: break
            target.onScan(scan.address, scan.advertId, scan.rssi, scan.txPower)
        }
    }

    // ------------------------------------------------------------------
    // Notification de premier plan
    // ------------------------------------------------------------------

    private fun startForegroundCompat() {
        ensureChannel()
        val notification = buildNotification(lastStatus)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Proximité",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Détection des membres NeoVibe autour de toi"
                setShowBadge(false)
            },
        )
    }

    /**
     * La notification DIT l'état réel.
     *
     * ⚠️ C'est le prolongement de la règle du moteur : une notification qui
     * annonce « détection active » alors que le Bluetooth est éteint est
     * exactement le mensonge qu'on vient de supprimer côté interface. Elle
     * serait même pire, puisqu'elle est visible en permanence.
     */
    private fun buildNotification(status: RadioStatus): Notification {
        val text = when (status) {
            is RadioStatus.Running ->
                if (status.advertising && status.scanning) "Détection active"
                else if (status.scanning) "Détection active — tu n'es pas annoncé"
                else "En veille — la diffusion a échoué"
            is RadioStatus.AdapterOff -> "En pause — le Bluetooth est éteint"
            is RadioStatus.PermissionsMissing -> "En pause — permission manquante"
            is RadioStatus.Unsupported -> "Indisponible sur cet appareil"
            is RadioStatus.Failed -> "En pause — ${status.message}"
            is RadioStatus.Starting -> "Démarrage…"
            is RadioStatus.Idle -> "En veille"
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("NeoVibe")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .build()
    }

    private fun updateNotification(status: RadioStatus) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification(status)) }
    }
}
