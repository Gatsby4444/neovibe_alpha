package com.neovibe.neovibe.publish

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Après un redémarrage du téléphone : s'il reste une publication en cours,
 * le service repart et la finit. Un démarrage au boot est l'une des
 * exemptions qui autorisent un service de premier plan depuis l'arrière-plan.
 *
 * ⚠️ Ne démarre QUE la file de publication — jamais la proximité : voir
 * le manifeste (`ACCESS_BACKGROUND_LOCATION`, RAPPELS #57).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (PublishStore(context).active().isEmpty()) return
        PublishService.kick(context)
    }
}
