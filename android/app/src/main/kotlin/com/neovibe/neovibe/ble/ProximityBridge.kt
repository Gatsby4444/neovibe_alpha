package com.neovibe.neovibe.ble

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Le pont Dart ↔ service. **Il ne contient aucune logique BLE.**
 *
 * Deux canaux, et la distinction est volontaire :
 *
 * - `neovibe/proximity` (méthodes) — les ORDRES du Dart : démarrer, arrêter,
 *   changer d'identifiant, ouvrir un lien, envoyer.
 * - `neovibe/proximity/events` (flux) — ce que la radio CONSTATE : état, scans,
 *   liens, trames.
 *
 * ⚠️ L'ancien code faisait passer les événements par `invokeMethod` sur le canal
 * de commandes, dans les deux sens. Un flux qui remonte n'a pas les mêmes règles
 * qu'un ordre qui descend — il n'attend pas de réponse, il peut n'avoir aucun
 * auditeur, et il doit survivre au remplacement de l'interface. Les mélanger,
 * c'est se condamner à la règle la plus permissive des deux.
 *
 * ⚠️ **Le pont est jetable, le service ne l'est pas.** L'interface peut mourir et
 * renaître ; à chaque fois un nouveau pont s'enregistre auprès du service, qui
 * lui rejoue son état courant et les scans mis de côté.
 */
class ProximityBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, BleEngine.Listener {

    private val methods = MethodChannel(messenger, "neovibe/proximity")
    private val events = EventChannel(messenger, "neovibe/proximity/events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    /** À appeler quand l'activité disparaît : le service, lui, reste. */
    fun dispose() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (ProximityBus.listener === this) ProximityBus.listener = null
    }

    // ------------------------------------------------------------------
    // Ordres
    // ------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // Diagnostic PUR : ce que la radio pourrait faire, sans rien
                // démarrer. C'est ce qui permet à l'interface de proposer la
                // bonne action AVANT que l'utilisateur bascule l'interrupteur.
                "probe" -> {
                    val blocker = evaluateRadio(context)
                    result.success((blocker ?: RadioStatus.Idle).toMap())
                }

                "start" -> {
                    val advertId = call.argument<ByteArray>("advertId")
                        ?: return result.error("ARG", "advertId manquant", null)
                    ProximityService.start(context, advertId)
                    result.success(null)
                }

                "stats" -> {
                    val service = ProximityService.instance
                    result.success(
                        service?.stats() ?: mapOf(
                            "rawScans" to 0,
                            "neoScans" to 0,
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                            "device" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                        ),
                    )
                }

                "stop" -> {
                    ProximityService.stop(context)
                    result.success(null)
                }

                "updateAdvert" -> {
                    val advertId = call.argument<ByteArray>("advertId")
                        ?: return result.error("ARG", "advertId manquant", null)
                    val service = ProximityService.instance
                    if (service == null) {
                        // Pas de service : l'identifiant n'a nulle part où aller.
                        // On le DIT, au lieu de laisser croire à une rotation.
                        result.error("NO_SERVICE", "Le service de proximité ne tourne pas", null)
                    } else {
                        service.updateAdvert(advertId)
                        result.success(null)
                    }
                }

                "connect" -> {
                    val address = call.argument<String>("address")
                        ?: return result.error("ARG", "address manquante", null)
                    val service = ProximityService.instance
                        ?: return result.error("NO_SERVICE", "Le service ne tourne pas", null)
                    service.connect(address) { error ->
                        if (error == null) {
                            result.success(mapOf("linkId" to address, "mtu" to service.mtuOf(address)))
                        } else {
                            result.error("CONNECT_FAILED", error, null)
                        }
                    }
                }

                "disconnect" -> {
                    val linkId = call.argument<String>("linkId")
                        ?: return result.error("ARG", "linkId manquant", null)
                    ProximityService.instance?.disconnect(linkId)
                    result.success(null)
                }

                "send" -> {
                    val linkId = call.argument<String>("linkId")
                        ?: return result.error("ARG", "linkId manquant", null)
                    val data = call.argument<ByteArray>("data")
                        ?: return result.error("ARG", "data manquante", null)
                    val service = ProximityService.instance
                        ?: return result.error("NO_SERVICE", "Le service ne tourne pas", null)
                    if (service.send(linkId, data)) {
                        result.success(null)
                    } else {
                        result.error("NO_LINK", "Lien $linkId introuvable", null)
                    }
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("BLE_ERROR", e.message ?: e.toString(), null)
        }
    }

    // ------------------------------------------------------------------
    // Flux
    // ------------------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
        // ⚠️ On DÉPOSE, on ne va pas chercher. Le service n'existe peut-être pas
        // encore — il ne démarre qu'à l'appel de `start`. L'ancienne version
        // faisait `ProximityService.instance?.bridge = this` ici, et le `?.`
        // avalait l'affectation en silence : le service tournait ensuite sans
        // jamais rien remonter au Dart.
        ProximityBus.listener = this
        // S'il tourne déjà, il rejoue ce qu'on a manqué.
        ProximityService.instance?.replayToBridge()
    }

    override fun onCancel(arguments: Any?) {
        if (ProximityBus.listener === this) ProximityBus.listener = null
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    override fun onStatus(status: RadioStatus) =
        emit(mapOf("event" to "status") + status.toMap())

    override fun onScan(address: String, advertId: ByteArray, rssi: Int) = emit(
        mapOf("event" to "scan", "address" to address, "advertId" to advertId, "rssi" to rssi),
    )

    override fun onLink(linkId: String, connected: Boolean, mtu: Int, incoming: Boolean) = emit(
        mapOf(
            "event" to "link",
            "linkId" to linkId,
            "connected" to connected,
            "mtu" to mtu,
            "incoming" to incoming,
        ),
    )

    override fun onFrame(linkId: String, data: ByteArray) =
        emit(mapOf("event" to "frame", "linkId" to linkId, "data" to data))
}
