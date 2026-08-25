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

                // ⚠️ **Les réglages de LOCALISATION du système, pas ceux de
                // l'app.** Aucune permission ne remplace l'interrupteur : sur
                // Android 10 et 11, c'est le service lui-même qu'il faut
                // allumer. Rétabli le 2026-08-25 avec `minSdk = 29`.
                "openLocationSettings" -> {
                    val intent = android.content.Intent(
                        android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS,
                    ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(null)
                }

                // ⚠️ **`updateAdvert` a ete SUPPRIME le 2026-08-25.** C'etait un
                // second chemin vers l'emission, reste d'avant le plan
                // d'annonces : aucun appelant Dart, et il ne pouvait pas porter
                // le TYPE du jeton.

                // ⚠️ **Le PLAN d'emission : la correction du point H.**
                //
                // Le Dart depose plusieurs heures de jetons d'avance, et le
                // service choisit lui-meme. Avant, le Dart poussait un
                // identifiant a chaque changement de creneau ; s'il mourait,
                // l'identifiant se figeait et l'appareil devenait invisible pour
                // tous ses amis, sans erreur ni trace.
                //
                // Les jetons ne sont PAS des secrets : ce sont des identifiants
                // deja calcules. Aucune cryptographie ne descend ici.
                "setAdvertPlan" -> {
                    val tokens = call.argument<ByteArray>("tokens")
                        ?: return result.error("ARG", "tokens manquants", null)
                    val fromSlot = (call.argument<Number>("fromSlot")
                        ?: return result.error("ARG", "fromSlot manquant", null)).toLong()
                    val slotMillis = (call.argument<Number>("slotMillis")
                        ?: return result.error("ARG", "slotMillis manquant", null)).toLong()
                    val slotCount = call.argument<Int>("slotCount")
                        ?: return result.error("ARG", "slotCount manquant", null)
                    val perSlot = call.argument<Int>("perSlot")
                        ?: return result.error("ARG", "perSlot manquant", null)
                    val tokenLength = call.argument<Int>("tokenLength")
                        ?: return result.error("ARG", "tokenLength manquant", null)
                    // ⚠️ Un octet de TYPE par jeton, dans le meme ordre. Le
                    // natif ne doit pas DEDUIRE lequel est public : le deduire,
                    // c'est reinventer en Kotlin une regle qui vit en Dart.
                    val types = call.argument<ByteArray>("types")
                        ?: return result.error("ARG", "types manquants", null)
                    val service = ProximityService.instance
                    if (service == null) {
                        result.error("NO_SERVICE", "Le service de proximite ne tourne pas", null)
                    } else {
                        service.setAdvertSchedule(
                            AdvertSchedule(
                                fromSlot = fromSlot,
                                slotMillis = slotMillis,
                                slotCount = slotCount,
                                perSlot = perSlot,
                                tokens = tokens,
                                tokenLength = tokenLength,
                                types = types,
                            ),
                        )
                        result.success(mapOf("validUntil" to service.scheduleValidUntil()))
                    }
                }

                // ⚠️ **La table de reconnaissance : le natif voit enfin par
                // lui-meme.** Elle ne contient aucune identite — des jetons et
                // des rangs. Le `tableId` revient avec chaque constat pour que
                // le Dart jette ceux d'une table perimee au lieu de les
                // attribuer a la mauvaise personne.
                "setRecognitionTable" -> {
                    val tokens = call.argument<ByteArray>("tokens")
                        ?: return result.error("ARG", "tokens manquants", null)
                    val tableId = call.argument<Int>("tableId")
                        ?: return result.error("ARG", "tableId manquant", null)
                    val fromSlot = (call.argument<Number>("fromSlot")
                        ?: return result.error("ARG", "fromSlot manquant", null)).toLong()
                    val slotMillis = (call.argument<Number>("slotMillis")
                        ?: return result.error("ARG", "slotMillis manquant", null)).toLong()
                    val slotCount = call.argument<Int>("slotCount")
                        ?: return result.error("ARG", "slotCount manquant", null)
                    val perSlot = call.argument<Int>("perSlot")
                        ?: return result.error("ARG", "perSlot manquant", null)
                    val tokenLength = call.argument<Int>("tokenLength")
                        ?: return result.error("ARG", "tokenLength manquant", null)
                    val service = ProximityService.instance
                    if (service == null) {
                        result.error("NO_SERVICE", "Le service de proximite ne tourne pas", null)
                    } else {
                        service.setRecognitionTable(
                            RecognitionTable(
                                tableId = tableId,
                                fromSlot = fromSlot,
                                slotMillis = slotMillis,
                                slotCount = slotCount,
                                perSlot = perSlot,
                                tokens = tokens,
                                tokenLength = tokenLength,
                            ),
                            slotMillis,
                        )
                        result.success(null)
                    }
                }

                // Ce que le service a constate pendant que le Dart etait absent.
                "takeSightings" -> {
                    val service = ProximityService.instance
                    result.success(
                        service?.takeSightings()?.map {
                            mapOf(
                                "tableId" to it.tableId,
                                "index" to it.friendIndex,
                                "slot" to it.slot,
                                "rssi" to it.rssi,
                                "txPower" to it.txPower,
                            )
                        } ?: emptyList<Map<String, Any?>>(),
                    )
                }

                "advertCapabilities" -> {
                    result.success(ProximityService.instance?.advertCapabilities() ?: mapOf<String, Any?>())
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

    override fun onScan(
        address: String,
        advertId: ByteArray,
        rssi: Int,
        txPower: Int,
        type: Byte,
    ) = emit(
        mapOf(
            "event" to "scan",
            "address" to address,
            "advertId" to advertId,
            "rssi" to rssi,
            "txPower" to txPower,
            // ⚠️ Le type monte jusqu'au Dart : c'est LUI qui detient la table
            // de reconnaissance faisant autorite, donc c'est lui qui decide
            // qu'un jeton prive inconnu se jette au lieu de s'afficher.
            "advertType" to type.toInt(),
        ),
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
