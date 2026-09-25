package com.neovibe.neovibe.events

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * **Le pont vers la présence d'événement** (`neovibe/event_presence`),
 * jetable comme les autres ponts : il naît et meurt avec l'activité, le
 * service survit.
 *
 * | méthode | ce qu'elle fait |
 * |---|---|
 * | `start(eventId, title)` | démarre le service de présence (type `location`) — depuis l'interface |
 * | `stop()` | l'arrête (j'ai quitté, l'événement est fermé) |
 * | `running` | le service tourne-t-il ? |
 *
 * Événements `neovibe/event_presence/events` : `{eventId, outcome}` à chaque
 * dépôt — `present`, `away`, `none`, `no_fix`, `offline`, `auth`, `stopped`.
 */
class EventPresenceBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, EventPresenceHub.Listener {

    private val channel = MethodChannel(messenger, "neovibe/event_presence")
    private val events = EventChannel(messenger, "neovibe/event_presence/events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        EventPresenceHub.add(this)
    }

    fun dispose() {
        EventPresenceHub.remove(this)
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val id = call.argument<String>("eventId")
                    ?: return result.error("BAD_ARGS", "eventId requis", null)
                EventPresenceService.start(context, id, call.argument<String>("title") ?: "Événement")
                result.success(null)
            }
            "stop" -> {
                EventPresenceService.stop(context)
                result.success(null)
            }
            "running" -> result.success(EventPresenceService.running)
            // Le carnet du service (2026-09-25), pour le diagnostic.
            "journal" -> result.success(
                com.neovibe.neovibe.ble.ServiceJournal.lire(
                    java.io.File(context.filesDir, EventPresenceService.JOURNAL),
                ),
            )
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onPresence(eventId: String?, outcome: String) {
        main.post { sink?.success(mapOf("eventId" to eventId, "outcome" to outcome)) }
    }
}
