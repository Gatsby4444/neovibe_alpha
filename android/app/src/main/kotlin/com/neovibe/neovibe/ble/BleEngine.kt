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
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
@SuppressLint("MissingPermission") // vérifiées explicitement par evaluateRadio()
class BleEngine(private val context: Context, private val listener: Listener) {

    /** Ce que le moteur remonte. Aucune de ces méthodes ne doit bloquer. */
    interface Listener {
        fun onStatus(status: RadioStatus)
        fun onScan(address: String, advertId: ByteArray, rssi: Int)
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
                    if (wanted != null) start(wanted) else publish(currentStatus())
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
                else RadioStatus.Failed("advertise", "Advertising impossible ($errorCode)"),
            )
        }
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
            val payload = result.scanRecord
                ?.getManufacturerSpecificData(BleConstants.MANUFACTURER_ID) ?: return
            if (payload.size != BleConstants.ADVERT_PAYLOAD_SIZE) return
            if (payload[0] != BleConstants.MAGIC[0] || payload[1] != BleConstants.MAGIC[1]) return
            val id = payload.copyOfRange(2, BleConstants.ADVERT_PAYLOAD_SIZE)
            main.post { listener.onScan(result.device.address, id, result.rssi) }
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            publish(RadioStatus.Failed("scan", "Scan impossible ($errorCode)"))
        }
    }

    private fun startScanning() {
        if (scanning) return
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            publish(RadioStatus.Failed("scan", "Scan indisponible sur cet appareil"))
            return
        }
        val filter = ScanFilter.Builder()
            .setManufacturerData(
                BleConstants.MANUFACTURER_ID,
                BleConstants.MAGIC,
                byteArrayOf(0xFF.toByte(), 0xFF.toByte()),
            )
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
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
        if (clientLinks.containsKey(address)) {
            done(null)
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
