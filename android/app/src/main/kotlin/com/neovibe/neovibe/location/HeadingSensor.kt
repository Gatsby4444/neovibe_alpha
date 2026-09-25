package com.neovibe.neovibe.location

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * **La boussole** (2026-09-25) — vers où pointe le haut du téléphone, pour
 * la flèche de mon point sur la carte (demande de Jay).
 *
 * ## Ce qu'elle fait, et rien d'autre
 *
 * La **cuisine** : elle écoute le capteur tant que quelqu'un l'écoute, et
 * publie chaque mesure telle quelle — l'angle par rapport au nord, et ce que
 * le téléphone dit de sa fiabilité. Elle ne lisse rien et ne trie rien :
 * adoucir la flèche est une décision d'affichage, prise par la carte.
 *
 * ## Le capteur
 *
 * `TYPE_ROTATION_VECTOR` : Android y fusionne boussole, accéléromètre et
 * gyroscope — bien plus stable que la boussole seule, qui tremble au moindre
 * mouvement. L'app est tenue en portrait (manifeste) : l'angle se lit sans
 * réorienter le repère.
 *
 * Événements publiés : `{deg: 0..360, fiabilite: 0..3}` (les niveaux
 * d'Android : 0 = inutilisable, à recalibrer ; 3 = haute). Un appareil sans
 * ce capteur publie une seule fois `{absent: true}` — dit, jamais deviné.
 *
 * iOS : `CLLocationManager.startUpdatingHeading` (`trueHeading`).
 */
class HeadingSensor(
    context: Context,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler, SensorEventListener {

    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val events = EventChannel(messenger, "neovibe/heading/events")
    private var sink: EventChannel.EventSink? = null
    private var fiabilite = SensorManager.SENSOR_STATUS_UNRELIABLE
    private val rotation = FloatArray(9)
    private val orientation = FloatArray(3)

    init {
        events.setStreamHandler(this)
    }

    fun dispose() {
        stop()
        events.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val capteur = sensors?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (capteur == null) {
            events.success(mapOf("absent" to true))
            return
        }
        sensors.registerListener(this, capteur, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) = stop()

    private fun stop() {
        sensors?.unregisterListener(this)
        sink = null
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        fiabilite = accuracy
    }

    override fun onSensorChanged(event: SensorEvent) {
        val s = sink ?: return
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        SensorManager.getOrientation(rotation, orientation)
        val deg = (Math.toDegrees(orientation[0].toDouble()) + 360.0) % 360.0
        s.success(mapOf("deg" to deg, "fiabilite" to fiabilite))
    }
}
