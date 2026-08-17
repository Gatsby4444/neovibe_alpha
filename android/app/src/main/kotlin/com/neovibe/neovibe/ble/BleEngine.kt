package com.neovibe.neovibe.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanCallback.SCAN_FAILED_ALREADY_STARTED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_INTERNAL_ERROR
import android.bluetooth.le.ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES
import android.bluetooth.le.ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Le moteur BLE : advertising, scan, serveur et client GATT.
 *
 * ## Ce qu'il est, et ce qu'il n'est PAS
 *
 * Il possède **le matériel**, rien d'autre. Il ne connaît ni identité, ni
 * chiffrement, ni profil, ni message : il diffuse un identifiant opaque, il
 * rapporte ceux qu'il voit, et il transporte des trames d'octets.
 *
 * ⚠️ **Il ne dépend d'aucune `Activity`** — c'est ce qui lui permet de vivre
 * dans un service et de survivre à la destruction de l'interface (décision de
 * Jay, 2026-08-16). Toute référence à une `Activity` réintroduirait la fragilité
 * qu'on est en train de supprimer.
 *
 * ## Les deux règles qu'il tient, et que l'ancienne couche ne tenait pas
 *
 * 1. **Il ne ment jamais sur son état.** Chaque échec produit un [RadioStatus]
 *    nommé. Il n'existe plus un seul `?: return` silencieux.
 * 2. **Il ne perd jamais un octet.** Les deux sens d'écriture ont leur file.
 */
/** Valeur d'Android quand l'emetteur n'annonce pas sa puissance. */
const val TX_POWER_UNKNOWN = 127

@SuppressLint("MissingPermission") // vérifiées explicitement par evaluateRadio()
class BleEngine(private val context: Context, private val listener: Listener) {

    /** Ce que le moteur remonte. Aucune de ces méthodes ne doit bloquer. */
    interface Listener {
        fun onStatus(status: RadioStatus)
        /**
         * [txPower] est la puissance d'emission annoncee par le pair, en dBm,
         * ou [TX_POWER_UNKNOWN] s'il ne l'annonce pas.
         */
        fun onScan(address: String, advertId: ByteArray, rssi: Int, txPower: Int)
        fun onLink(linkId: String, connected: Boolean, mtu: Int, incoming: Boolean)
        fun onFrame(linkId: String, data: ByteArray)
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager get() =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var advertising = false
    private var scanning = false
    private var gattServer: BluetoothGattServer? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null

    private val clientLinks = ConcurrentHashMap<String, ClientLink>()
    private val serverCentrals = ConcurrentHashMap<String, BluetoothDevice>()
    private val serverMtus = ConcurrentHashMap<String, Int>()

    /**
     * L'ID que l'on DOIT diffuser tant qu'on est censé être visible.
     *
     * C'est la mémoire du moteur : elle survit à une coupure de Bluetooth, et
     * c'est elle qui permet de repartir tout seul quand l'adaptateur revient —
     * sans que l'utilisateur ait à toucher quoi que ce soit.
     */
    private var desiredAdvertId: ByteArray? = null

    private var lastPublished: RadioStatus? = null

    /**
     * Annonces BLE recues, **toutes applications confondues**.
     *
     * ⚠️ C'est l'instrument qui manquait. Avec le seul etat « detection
     * active », deux pannes tres differentes se ressemblaient :
     *
     * - `rawScans == 0` → la radio ne livre **rien**. Le probleme est sous nous
     *   (permission, puce, bridage systeme) ;
     * - `rawScans > 0` mais `neoScans == 0` → la radio livre, mais **aucune
     *   annonce NeoVibe n'arrive**. Le probleme est chez celui d'en face, ou
     *   dans le contenu de son annonce.
     *
     * Un seul chiffre separe donc « je n'entends rien » de « personne ne
     * parle » — deux phrases que l'ancienne interface confondait.
     */
    @Volatile
    var rawScans = 0
        private set

    /** Parmi elles, celles qui portent notre signature. */
    @Volatile
    var neoScans = 0
        private set

    /**
     * Les chemins physiques ouverts, **par role**, adresse par adresse.
     *
     * ⚠️ **Une adresse peut en porter DEUX a la fois, et le Dart n'en voit
     * qu'un.** Nous sommes central vers un pair (`clientLinks`) pendant que ce
     * meme pair est central vers nous (`serverCentrals`) : deux connexions GATT
     * independantes, deux durees de vie, un seul `linkId` — l'adresse.
     *
     * Trois consequences suivent de cette confusion, et aucune ne leve :
     *
     * 1. la mort d'UN chemin est annoncee au Dart comme la mort du lien, alors
     *    que l'autre vit encore ;
     * 2. [send] prefere toujours le chemin client — il peut donc changer de
     *    transport en cours de conversation, sans que personne ne le decide ;
     * 3. [connect] rend un succes **immediat** si un chemin client existe, sans
     *    emettre le moindre evenement de lien : le Dart attend alors une
     *    poignee de main qui ne partira jamais.
     *
     * ⚠️ **Ce compteur ne corrige rien — il MESURE.** Le cas des deux chemins
     * simultanes est deduit de la lecture du code, pas observe sur un appareil.
     * Tant que `bothPaths` reste a zero sur les appareils de Jay, l'hypothese
     * est fausse et il ne faut rien changer ici. Consigne du projet : ne jamais
     * livrer un correctif fonde sur une deduction.
     */
    val pathStats: Map<String, Any?>
        get() {
            val client = clientLinks.keys.toSet()
            val server = serverCentrals.keys.toSet()
            val both = client intersect server
            return mapOf(
                "clientPaths" to client.size,
                "serverPaths" to server.size,
                "bothPaths" to both.size,
                "bothPathsPeak" to bothPathsPeak,
            )
        }

    /**
     * Le maximum jamais atteint par `bothPaths`.
     *
     * ⚠️ **Un instantane ne peut pas prouver un cas transitoire.** Les deux
     * chemins peuvent coexister trois secondes et disparaitre : releve au
     * moment ou Jay envoie son rapport, `bothPaths` vaudrait zero et on en
     * conclurait — a tort — que le cas n'arrive jamais. Ce seau-ci, lui, peut
     * contenir la preuve du contraire.
     */
    @Volatile
    var bothPathsPeak = 0
        private set

    /** A appeler apres toute ouverture de chemin, dans l'un ou l'autre role. */
    private fun notePaths() {
        val both = (clientLinks.keys intersect serverCentrals.keys).size
        if (both > bothPathsPeak) bothPathsPeak = both
    }

    // ------------------------------------------------------------------
    // Cycle de vie
    // ------------------------------------------------------------------

    fun attach() {
        context.registerReceiver(
            adapterWatcher,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
        )
        publish(currentStatus())
    }

    fun detach() {
        try {
            context.unregisterReceiver(adapterWatcher)
        } catch (_: IllegalArgumentException) {
            // Jamais enregistré : rien à faire.
        }
        stop()
    }

    /**
     * Demande à être visible et à détecter, avec [advertId].
     *
     * Rend `true` si le matériel a démarré. Sinon l'appelant n'a **rien** à
     * déduire : le [RadioStatus] publié dit exactement pourquoi.
     *
     * ⚠️ L'intention est mémorisée **même en cas d'échec** : si le Bluetooth est
     * éteint, on veut repartir dès qu'il revient. C'est le cœur de la
     * résistance aux aléas.
     */
    fun start(advertId: ByteArray): Boolean {
        desiredAdvertId = advertId
        scanRetried = false
        rawScans = 0
        neoScans = 0
        val blocker = evaluateRadio(context)
        if (blocker != null) {
            publish(blocker)
            return false
        }
        publish(RadioStatus.Starting)
        return try {
            startServer()
            startAdvertising(advertId)
            startScanning()
            publish(currentStatus())
            true
        } catch (e: Exception) {
            publish(RadioStatus.Failed("start", e.message ?: e.toString()))
            false
        }
    }

    /** Arrêt VOULU : l'intention disparaît, on ne repartira pas tout seul. */
    fun stop() {
        desiredAdvertId = null
        teardown()
        publish(currentStatus())
    }

    fun updateAdvert(advertId: ByteArray) {
        desiredAdvertId = advertId
        if (evaluateRadio(context) != null) return
        stopAdvertising()
        startAdvertising(advertId)
        publish(currentStatus())
    }

    /** Coupe le matériel sans toucher à l'intention (Bluetooth qui s'éteint). */
    private fun teardown() {
        stopAdvertising()
        stopScanning()
        clientLinks.values.forEach { runCatching { it.gatt?.disconnect() } }
        clientLinks.clear()
        serverCentrals.clear()
        serverMtus.clear()
        runCatching { gattServer?.close() }
        gattServer = null
        txCharacteristic = null
    }

    private fun currentStatus(): RadioStatus {
        val blocker = evaluateRadio(context)
        if (blocker != null) return blocker
        if (desiredAdvertId == null) return RadioStatus.Idle
        return RadioStatus.Running(advertising, scanning)
    }

    private fun publish(status: RadioStatus) {
        if (status == lastPublished) return
        lastPublished = status
        main.post { listener.onStatus(status) }
    }

    /**
     * L'adaptateur qui s'éteint ou se rallume.
     *
     * ⚠️ **C'est la pièce qui manquait entièrement.** Sans elle, rallumer le
     * Bluetooth ne relançait rien : `start()` avait déjà « réussi », il n'était
     * jamais rappelé, et il fallait couper puis remettre l'interrupteur de
     * visibilité dans l'app — ce que personne ne devine.
     */
    private val adapterWatcher = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> {
                    val wanted = desiredAdvertId
                    if (wanted == null) {
                        publish(currentStatus())
                        return
                    }
                    // PAS TOUT DE SUITE. STATE_ON annonce que l'adaptateur est
                    // allume, pas que la pile BLE accepte deja un scan :
                    // demarrer dans la foulee echoue souvent en erreur interne,
                    // et on aurait alors accuse le code d'un defaut qui n'est
                    // qu'un defaut de rythme.
                    publish(RadioStatus.Starting)
                    main.postDelayed({ if (desiredAdvertId != null) start(wanted) }, 1_200)
                }
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                    // Les liens sont morts avec la radio : on le DIT, au lieu de
                    // laisser le haut croire qu'ils tiennent encore.
                    val lost = clientLinks.keys.toList() + serverCentrals.keys.toList()
                    teardown()
                    main.post {
                        lost.forEach { listener.onLink(it, false, BleConstants.DEFAULT_MTU, false) }
                    }
                    publish(currentStatus())
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Advertising et scan
    // ------------------------------------------------------------------

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertising = true
            publish(currentStatus())
        }

        override fun onStartFailure(errorCode: Int) {
            advertising = false
            // L'advertising peut échouer SEUL (trop d'annonceurs, pile occupée)
            // sans emporter le scan : on reste donc en Running, avec
            // `advertising = false`. C'est visible, et c'est vrai.
            publish(
                if (scanning) currentStatus()
                else RadioStatus.Failed("advertise", advertiseFailureText(errorCode)),
            )
        }
    }

    private fun advertiseFailureText(code: Int): String = when (code) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE ->
            "L'annonce est trop grosse pour cet appareil."
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS ->
            "Trop d'applications diffusent en meme temps sur cet appareil."
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED ->
            "Une diffusion precedente n'a pas pu etre arretee."
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR ->
            "Le Bluetooth de l'appareil a rencontre une erreur interne."
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED ->
            "Cet appareil ne sait pas se rendre visible en Bluetooth basse " +
                "consommation."
        else -> "La diffusion a echoue (code Android $code)."
    }

    private fun startAdvertising(advertId: ByteArray) {
        if (advertising) return
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            publish(RadioStatus.Failed("advertise", "Advertising indisponible sur cet appareil"))
            return
        }
        val data = AdvertiseData.Builder()
            .addManufacturerData(BleConstants.MANUFACTURER_ID, BleConstants.MAGIC + advertId)
            .setIncludeDeviceName(false)
            // ⚠️ **La puissance d'emission voyage avec l'annonce.**
            //
            // Sans elle, celui qui recoit ne connait que le RSSI - la puissance
            // ARRIVEE - et doit DEVINER celle qui est partie. Or elle varie
            // fortement d'un appareil a l'autre : deux telephones cote a cote
            // peuvent emettre a 6 dB d'ecart, soit un facteur ~2 sur la distance
            // deduite. La transmettre supprime cette inconnue-la.
            //
            // Cout : 3 octets sur les 31 de l'annonce. Notre charge utile en
            // occupe 25 - il reste de la place, mais tout juste : ne rien
            // ajouter d'autre sans recompter.
            .setIncludeTxPowerLevel(true)
            .build()
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true) // connectable : le chat passe par le GATT
            .setTimeout(0)
            .build()
        advertiser.startAdvertising(settings, data, advertiseCallback)
        // `advertising` n'est PAS posé ici : il l'est dans onStartSuccess.
        // L'ancienne couche le posait tout de suite — donc elle annonçait
        // « ça diffuse » avant de savoir si ça diffusait.
    }

    private fun stopAdvertising() {
        if (!advertising) return
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        advertising = false
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            // Compte AVANT tout tri : c'est ce chiffre qui dit si la radio
            // livre quelque chose, independamment de ce qu'on en garde.
            rawScans++
            val payload = result.scanRecord
                ?.getManufacturerSpecificData(BleConstants.MANUFACTURER_ID) ?: return
            if (payload.size != BleConstants.ADVERT_PAYLOAD_SIZE) return
            if (payload[0] != BleConstants.MAGIC[0] || payload[1] != BleConstants.MAGIC[1]) return
            neoScans++
            val id = payload.copyOfRange(2, BleConstants.ADVERT_PAYLOAD_SIZE)
            // `txPower` vaut TX_POWER_NOT_PRESENT (127) si l'emetteur ne
            // l'annonce pas - un appareil sur une version anterieure, par
            // exemple. On transmet tel quel : c'est au-dessus de decider quoi
            // en faire, et inventer une valeur par defaut ici la rendrait
            // indiscernable d'une vraie mesure.
            val tx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                result.txPower
            } else {
                TX_POWER_UNKNOWN
            }
            main.post { listener.onScan(result.device.address, id, result.rssi, tx) }
        }

        /**
         * Un code d'erreur brut n'est PAS un message.
         *
         * La premiere version publiait « Scan impossible (6) ». Jay l'a lu au
         * test et n'a rien pu en faire - c'est le contraire de ce que ce
         * chantier cherche : nommer une cause ACTIONNABLE. Deux de ces six cas
         * se reparent d'ailleurs tout seuls, encore fallait-il les distinguer.
         */
        override fun onScanFailed(errorCode: Int) {
            scanning = false
            when (errorCode) {
                SCAN_FAILED_ALREADY_STARTED -> {
                    // Un scan de NOTRE application est encore enregistre cote
                    // systeme : typiquement apres une coupure du Bluetooth, ou
                    // stopScan n'a pas pu s'executer (le scanner etait deja
                    // null). On degage la place et on reprend, une seule fois.
                    dropScanRegistration()
                    if (retryScan()) return
                }
                SCAN_FAILED_SCANNING_TOO_FREQUENTLY -> {
                    // Android limite un meme processus a quelques demarrages de
                    // scan par tranche de 30 s. Ce n'est pas une panne, c'est
                    // une attente : on le DIT, et on repart tout seul.
                    publish(
                        RadioStatus.Failed(
                            "scanThrottled",
                            "Android a mis la detection en pause : trop de " +
                                "demarrages en peu de temps. Reprise automatique " +
                                "dans une trentaine de secondes.",
                        ),
                    )
                    main.postDelayed({ if (desiredAdvertId != null) startScanning() }, 35_000)
                    return
                }
            }
            publish(RadioStatus.Failed("scan", scanFailureText(errorCode)))
        }
    }

    /**
     * Retire notre enregistrement de scan aupres du systeme.
     *
     * Methode et non lambda sur place : ecrite dans l'initialiseur de
     * `scanCallback`, elle s'y serait citee elle-meme et Kotlin ne pouvait plus
     * inferer le type de la propriete.
     */
    private fun dropScanRegistration() {
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
    }

    /** Une seule reprise par demarrage : sinon on boucle sur un defaut reel. */
    private var scanRetried = false

    private fun retryScan(): Boolean {
        if (scanRetried) return false
        scanRetried = true
        main.postDelayed({ if (desiredAdvertId != null) startScanning() }, 400)
        return true
    }

    private fun scanFailureText(code: Int): String = when (code) {
        SCAN_FAILED_ALREADY_STARTED ->
            "Une detection precedente n'a pas pu etre arretee. Coupe puis " +
                "rallume la visibilite."
        SCAN_FAILED_APPLICATION_REGISTRATION_FAILED ->
            "Android a refuse d'enregistrer la detection. Redemarrer le " +
                "Bluetooth regle presque toujours ce cas."
        SCAN_FAILED_INTERNAL_ERROR ->
            "Le Bluetooth de l'appareil a rencontre une erreur interne. " +
                "Coupe puis rallume le Bluetooth."
        SCAN_FAILED_FEATURE_UNSUPPORTED ->
            "Cet appareil ne sait pas faire ce type de detection."
        SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES ->
            "Le Bluetooth de l'appareil est sature par d'autres applications."
        SCAN_FAILED_SCANNING_TOO_FREQUENTLY ->
            "Trop de demarrages de detection en peu de temps. Attends une " +
                "trentaine de secondes."
        else -> "La detection a echoue (code Android $code)."
    }

    private fun startScanning() {
        if (scanning) return
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            publish(RadioStatus.Failed("scan", "Scan indisponible sur cet appareil"))
            return
        }
        // ⚠️ **Un filtre qui accepte TOUT, et le tri se fait en logiciel.**
        //
        // Le filtre precedent portait sur les donnees de fabricant
        // (`setManufacturerData`). C'est la bonne facon de faire *en theorie* :
        // le tri est delegue a la puce, l'application n'est reveillee que pour
        // ce qui l'interesse.
        //
        // En pratique, **ce filtrage materiel est notoirement inegal d'un
        // fabricant a l'autre** : certaines puces ne savent pas appliquer un
        // masque sur les donnees de fabricant et laissent passer tout, d'autres
        // ne laissent rien passer du tout. Le second cas donne exactement ce que
        // Jay a constate le 2026-08-16 : deux appareils qui s'annoncent en
        // parfaite sante, et un seul qui voit l'autre.
        //
        // Le tri logiciel, lui, existait deja dans `onScanResult` et n'a jamais
        // dependu du materiel. Le filtre materiel n'etait donc qu'une
        // optimisation - et une optimisation dont la defaillance est
        // silencieuse et depend de l'appareil est pire que pas d'optimisation.
        //
        // ⚠️ La liste reste NON VIDE : sur plusieurs versions d'Android, un scan
        // sans aucun filtre est refuse ou bride en arriere-plan. Un filtre vide
        // accepte tout tout en gardant le chemin "scan filtre" du systeme.
        //
        // Contrepartie assumee : on est reveille pour chaque annonce BLE des
        // environs, pas seulement les notres. Mesurable via `stats()`.
        val filter = ScanFilter.Builder().build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        scanning = true
    }

    private fun stopScanning() {
        if (!scanning) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
    }

    // ------------------------------------------------------------------
    // Serveur GATT (nous sommes périphérique)
    // ------------------------------------------------------------------

    /**
     * File des notifications SORTANTES, par central.
     *
     * ⚠️ **C'est un défaut trouvé en reconstruisant, absent du diagnostic** :
     * l'ancienne couche appelait `notifyCharacteristicChanged` en rafale sans
     * attendre `onNotificationSent`. La pile Bluetooth n'accepte qu'une
     * notification en vol : les suivantes étaient **perdues, sans erreur**.
     * Toute trame dépassant un MTU était donc corrompue dans ce sens — et comme
     * le réassembleur d'en face ne voit qu'un flux d'octets, il attendait
     * indéfiniment la fin d'une trame qui n'arriverait jamais.
     */
    private val notifyQueues = ConcurrentHashMap<String, ConcurrentLinkedQueue<ByteArray>>()
    private val notifyInFlight = ConcurrentHashMap<String, Boolean>()

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val known = serverCentrals.remove(device.address) != null
                serverMtus.remove(device.address)
                notifyQueues.remove(device.address)
                notifyInFlight.remove(device.address)
                if (known) {
                    main.post {
                        listener.onLink(device.address, false, BleConstants.DEFAULT_MTU, true)
                    }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            serverMtus[device.address] = mtu
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid == BleConstants.RX_UUID) {
                main.post { listener.onFrame(device.address, value) }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (descriptor.uuid == BleConstants.CCCD_UUID) {
                serverCentrals[device.address] = device
                notePaths()
                val mtu = serverMtus[device.address] ?: BleConstants.DEFAULT_MTU
                main.post { listener.onLink(device.address, true, mtu, true) }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            notifyInFlight[device.address] = false
            drainNotify(device.address)
        }
    }

    private fun startServer() {
        if (gattServer != null) return
        val server = manager?.openGattServer(context, serverCallback)
        if (server == null) {
            publish(RadioStatus.Failed("gatt", "Serveur GATT indisponible"))
            return
        }
        val service = BluetoothGattService(
            BleConstants.SERVICE_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        )
        val rx = BluetoothGattCharacteristic(
            BleConstants.RX_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val tx = BluetoothGattCharacteristic(
            BleConstants.TX_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            0,
        )
        tx.addDescriptor(
            BluetoothGattDescriptor(
                BleConstants.CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        service.addCharacteristic(rx)
        service.addCharacteristic(tx)
        server.addService(service)
        gattServer = server
        txCharacteristic = tx
    }

    @Synchronized
    private fun drainNotify(address: String) {
        if (notifyInFlight[address] == true) return
        val queue = notifyQueues[address] ?: return
        val next = queue.poll() ?: return
        val device = serverCentrals[address] ?: return
        val server = gattServer ?: return
        val tx = txCharacteristic ?: return
        notifyInFlight[address] = true
        @Suppress("DEPRECATION")
        tx.value = next
        @Suppress("DEPRECATION")
        server.notifyCharacteristicChanged(device, tx, false)
    }

    // ------------------------------------------------------------------
    // Client GATT (nous sommes central)
    // ------------------------------------------------------------------

    private inner class ClientLink(val address: String) : BluetoothGattCallback() {
        var gatt: BluetoothGatt? = null
        var rx: BluetoothGattCharacteristic? = null
        var mtu = BleConstants.DEFAULT_MTU
        var ready = false
        var onReady: ((String?) -> Unit)? = null
        val writeQueue = ConcurrentLinkedQueue<ByteArray>()
        var writing = false

        private fun settle(error: String?) {
            val callback = onReady
            onReady = null
            if (callback != null) main.post { callback(error) }
        }

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestMtu(512)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val wasReady = ready
                ready = false
                settle("Connexion BLE perdue ($status)")
                if (clientLinks.remove(address) != null && wasReady) {
                    main.post { listener.onLink(address, false, mtu, false) }
                }
                runCatching { g.close() }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, newMtu: Int, status: Int) {
            mtu = newMtu
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val service = g.getService(BleConstants.SERVICE_UUID)
            val rxChar = service?.getCharacteristic(BleConstants.RX_UUID)
            val txChar = service?.getCharacteristic(BleConstants.TX_UUID)
            if (rxChar == null || txChar == null) {
                settle("Service NeoVibe absent")
                g.disconnect()
                return
            }
            rx = rxChar
            g.setCharacteristicNotification(txChar, true)
            val cccd = txChar.getDescriptor(BleConstants.CCCD_UUID)
            if (cccd == null) {
                settle("Descripteur de notification absent")
                g.disconnect()
                return
            }
            @Suppress("DEPRECATION")
            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            g.writeDescriptor(cccd)
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            ready = true
            settle(null)
            notePaths()
            main.post { listener.onLink(address, true, mtu, false) }
        }

        @Deprecated("Signature API < 33")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == BleConstants.TX_UUID) {
                @Suppress("DEPRECATION")
                val data = characteristic.value ?: return
                main.post { listener.onFrame(address, data) }
            }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            writing = false
            drainQueue()
        }

        fun enqueue(data: ByteArray) {
            writeQueue.add(data)
            drainQueue()
        }

        @Synchronized
        fun drainQueue() {
            if (writing) return
            val next = writeQueue.peek() ?: return
            val g = gatt ?: return
            val c = rx ?: return
            writeQueue.poll()
            writing = true
            @Suppress("DEPRECATION")
            c.value = next
            @Suppress("DEPRECATION")
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            @Suppress("DEPRECATION")
            g.writeCharacteristic(c)
        }
    }

    /** Ouvre un lien sortant. [done] reçoit `null` en cas de succès, sinon le motif. */
    fun connect(address: String, done: (String?) -> Unit) {
        val blocker = evaluateRadio(context)
        if (blocker != null) {
            publish(blocker)
            done("Radio indisponible")
            return
        }
        // ⚠️ **Un lien deja ouvert doit se REANNONCER, pas juste dire « ok ».**
        //
        // Ce bloc rendait un succes immediat, sans emettre le moindre
        // `onLink`. Or l'appelant Dart demande une connexion precisement parce
        // qu'il n'a plus de canal : lui repondre « c'est deja fait » sans lui
        // donner l'evenement dont il a besoin le laisse attendre 8 s, puis
        // echouer sur « poignee de main impossible » — et l'etat est COLLANT,
        // tant que la radio ne lache pas d'elle-meme.
        //
        // Une fonction qui annonce un succes sans produire l'effet observable
        // que son appelant attend est un mensonge, meme quand elle dit vrai.
        val existant = clientLinks[address]
        if (existant != null) {
            if (existant.ready) {
                main.post { listener.onLink(address, true, existant.mtu, false) }
                done(null)
            } else {
                // La connexion est en cours : on se greffe sur son resultat au
                // lieu d'en ouvrir une seconde.
                val precedent = existant.onReady
                existant.onReady = { error ->
                    precedent?.invoke(error)
                    done(error)
                }
            }
            return
        }
        val device = adapter?.getRemoteDevice(address)
        if (device == null) {
            done("Adresse inconnue")
            return
        }
        val link = ClientLink(address)
        link.onReady = done
        clientLinks[address] = link
        link.gatt = device.connectGatt(context, false, link, BluetoothDevice.TRANSPORT_LE)
    }

    fun disconnect(linkId: String) {
        clientLinks.remove(linkId)?.let { runCatching { it.gatt?.disconnect() } }
        serverCentrals.remove(linkId)?.let { device ->
            runCatching { gattServer?.cancelConnection(device) }
        }
    }

    /** MTU négocié d'un lien, quel que soit le sens. */
    fun mtuOf(linkId: String): Int =
        clientLinks[linkId]?.mtu ?: serverMtus[linkId] ?: BleConstants.DEFAULT_MTU

    /** Envoie un morceau. Rend `false` si le lien n'existe pas. */
    fun send(linkId: String, data: ByteArray): Boolean {
        clientLinks[linkId]?.let {
            it.enqueue(data)
            return true
        }
        if (serverCentrals.containsKey(linkId)) {
            notifyQueues.getOrPut(linkId) { ConcurrentLinkedQueue() }.add(data)
            drainNotify(linkId)
            return true
        }
        return false
    }
}
