package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.app.Activity
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
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Couche BLE native NeoVibe : le « tuyau » du ping 100 % local
 * (chantier validé par Jay 2026-07-13).
 *
 * - Advertising : trame manufacturerData 0xFFFF "NV" + ID ROTATIF 16 octets
 *   (même format de trame que la V1, mais l'ID change toutes les ~15 min —
 *   anti-pistage ; la rotation est pilotée par le Dart via updateAdvert).
 * - Scan filtré sur cette signature.
 * - Serveur GATT connectable + client GATT : un lien = un tuyau d'octets
 *   BIDIRECTIONNEL (write → RX, notify ← TX). Toute la logique de protocole
 *   (poignée de main chiffrée, profils, messages, certificats) vit en Dart —
 *   le natif ne transporte que des trames opaques.
 */
@SuppressLint("MissingPermission") // permissions demandées côté Dart
class NativeBle(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val MANUFACTURER_ID = 0xFFFF
        val MAGIC = byteArrayOf(0x4E, 0x56) // "NV"
        val SERVICE_UUID: UUID = UUID.fromString("53d70001-8a3f-4f95-9b6c-4e656f566962")
        val RX_UUID: UUID = UUID.fromString("53d70002-8a3f-4f95-9b6c-4e656f566962")
        val TX_UUID: UUID = UUID.fromString("53d70003-8a3f-4f95-9b6c-4e656f566962")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val channel = MethodChannel(messenger, "neovibe/ble")
    private val main = Handler(Looper.getMainLooper())
    private val manager =
        activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter get() = manager.adapter

    private var advertising = false
    private var scanning = false
    private var gattServer: BluetoothGattServer? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null

    /** Liens où NOUS sommes central (nous avons initié la connexion). */
    private val clientLinks = ConcurrentHashMap<String, ClientLink>()

    /** Centrals abonnés à notre TX (liens où nous sommes périphérique). */
    private val serverCentrals = ConcurrentHashMap<String, BluetoothDevice>()
    private val serverMtus = ConcurrentHashMap<String, Int>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val advertId = call.argument<ByteArray>("advertId")!!
                    startServer()
                    startAdvertising(advertId)
                    startScanning()
                    result.success(null)
                }
                "updateAdvert" -> {
                    val advertId = call.argument<ByteArray>("advertId")!!
                    stopAdvertising()
                    startAdvertising(advertId)
                    result.success(null)
                }
                "stop" -> {
                    stopAll()
                    result.success(null)
                }
                "connect" -> connect(call.argument<String>("address")!!, result)
                "disconnect" -> {
                    disconnectLink(call.argument<String>("linkId")!!)
                    result.success(null)
                }
                "send" -> send(
                    call.argument<String>("linkId")!!,
                    call.argument<ByteArray>("data")!!,
                    result,
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("BLE_ERROR", e.message, null)
        }
    }

    private fun emit(method: String, args: Map<String, Any?>) {
        main.post { channel.invokeMethod(method, args) }
    }

    // ------------------------------------------------------------------
    // Advertising + scan
    // ------------------------------------------------------------------

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            emit("onError", mapOf("message" to "Advertising impossible ($errorCode)"))
        }
    }

    private fun startAdvertising(advertId: ByteArray) {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val data = AdvertiseData.Builder()
            .addManufacturerData(MANUFACTURER_ID, MAGIC + advertId)
            .setIncludeDeviceName(false)
            .build()
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true) // connectable : le chat passe par le GATT
            .setTimeout(0)
            .build()
        advertiser.startAdvertising(settings, data, advertiseCallback)
        advertising = true
    }

    private fun stopAdvertising() {
        if (!advertising) return
        adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        advertising = false
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val payload = result.scanRecord
                ?.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
            if (payload.size != 18) return
            if (payload[0] != MAGIC[0] || payload[1] != MAGIC[1]) return
            emit(
                "onScan",
                mapOf(
                    "address" to result.device.address,
                    "advertId" to payload.copyOfRange(2, 18),
                    "rssi" to result.rssi,
                ),
            )
        }
    }

    private fun startScanning() {
        if (scanning) return
        val scanner = adapter?.bluetoothLeScanner ?: return
        // Filtre : nos trames uniquement (préfixe "NV" du manufacturerData).
        val filter = ScanFilter.Builder()
            .setManufacturerData(MANUFACTURER_ID, MAGIC, byteArrayOf(0xFF.toByte(), 0xFF.toByte()))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        scanning = true
    }

    private fun stopScanning() {
        if (!scanning) return
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        scanning = false
    }

    // ------------------------------------------------------------------
    // Serveur GATT (nous sommes périphérique)
    // ------------------------------------------------------------------

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: BluetoothDevice,
            status: Int,
            newState: Int,
        ) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (serverCentrals.remove(device.address) != null) {
                    emit("onLink", mapOf("linkId" to device.address, "connected" to false))
                }
                serverMtus.remove(device.address)
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
            if (characteristic.uuid == RX_UUID) {
                emit("onFrame", mapOf("linkId" to device.address, "data" to value))
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null,
                )
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
            if (descriptor.uuid == CCCD_UUID) {
                // Le central s'abonne à TX : le lien entrant est prêt.
                serverCentrals[device.address] = device
                emit(
                    "onLink",
                    mapOf(
                        "linkId" to device.address,
                        "connected" to true,
                        "mtu" to (serverMtus[device.address] ?: 23),
                        "incoming" to true,
                    ),
                )
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null,
                )
            }
        }
    }

    private fun startServer() {
        if (gattServer != null) return
        val server = manager.openGattServer(activity, serverCallback) ?: return
        val service = BluetoothGattService(
            SERVICE_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        )
        val rx = BluetoothGattCharacteristic(
            RX_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val tx = BluetoothGattCharacteristic(
            TX_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            0,
        )
        tx.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
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

    // ------------------------------------------------------------------
    // Client GATT (nous sommes central)
    // ------------------------------------------------------------------

    private inner class ClientLink(val address: String) : BluetoothGattCallback() {
        var gatt: BluetoothGatt? = null
        var rx: BluetoothGattCharacteristic? = null
        var mtu = 23
        var connectResult: MethodChannel.Result? = null
        val writeQueue = ConcurrentLinkedQueue<ByteArray>()
        var writing = false

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestMtu(512)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val pending = connectResult
                connectResult = null
                main.post {
                    pending?.error("CONNECT_FAILED", "Connexion BLE perdue ($status)", null)
                }
                if (clientLinks.remove(address) != null && pending == null) {
                    emit("onLink", mapOf("linkId" to address, "connected" to false))
                }
                g.close()
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, newMtu: Int, status: Int) {
            mtu = newMtu
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val service = g.getService(SERVICE_UUID)
            val rxChar = service?.getCharacteristic(RX_UUID)
            val txChar = service?.getCharacteristic(TX_UUID)
            if (rxChar == null || txChar == null) {
                val pending = connectResult
                connectResult = null
                main.post {
                    pending?.error("NO_SERVICE", "Service NeoVibe absent", null)
                }
                g.disconnect()
                return
            }
            rx = rxChar
            g.setCharacteristicNotification(txChar, true)
            val cccd = txChar.getDescriptor(CCCD_UUID)
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
            // Abonnement TX posé : le lien sortant est prêt.
            val pending = connectResult
            connectResult = null
            main.post { pending?.success(mapOf("linkId" to address, "mtu" to mtu)) }
            emit(
                "onLink",
                mapOf(
                    "linkId" to address,
                    "connected" to true,
                    "mtu" to mtu,
                    "incoming" to false,
                ),
            )
        }

        @Deprecated("API 33")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == TX_UUID) {
                @Suppress("DEPRECATION")
                emit("onFrame", mapOf("linkId" to address, "data" to characteristic.value))
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
            val next = writeQueue.poll() ?: return
            val g = gatt ?: return
            val c = rx ?: return
            writing = true
            @Suppress("DEPRECATION")
            c.value = next
            @Suppress("DEPRECATION")
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            @Suppress("DEPRECATION")
            g.writeCharacteristic(c)
        }
    }

    private fun connect(address: String, result: MethodChannel.Result) {
        val device = adapter?.getRemoteDevice(address)
            ?: return result.error("BLE_ERROR", "Adaptateur indisponible", null)
        val link = ClientLink(address)
        link.connectResult = result
        clientLinks[address] = link
        link.gatt = device.connectGatt(activity, false, link, BluetoothDevice.TRANSPORT_LE)
    }

    private fun disconnectLink(linkId: String) {
        clientLinks.remove(linkId)?.gatt?.disconnect()
        serverCentrals.remove(linkId)?.let { device ->
            gattServer?.cancelConnection(device)
        }
    }

    private fun send(linkId: String, data: ByteArray, result: MethodChannel.Result) {
        val client = clientLinks[linkId]
        if (client != null) {
            client.enqueue(data)
            result.success(null)
            return
        }
        val central = serverCentrals[linkId]
        val server = gattServer
        val tx = txCharacteristic
        if (central != null && server != null && tx != null) {
            @Suppress("DEPRECATION")
            tx.value = data
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(central, tx, false)
            result.success(null)
            return
        }
        result.error("NO_LINK", "Lien $linkId introuvable", null)
    }

    private fun stopAll() {
        stopAdvertising()
        stopScanning()
        clientLinks.values.forEach { it.gatt?.disconnect() }
        clientLinks.clear()
        serverCentrals.clear()
        gattServer?.close()
        gattServer = null
        txCharacteristic = null
    }
}
