package com.neovibe.neovibe.ble

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler

/**
 * **Y a-t-il un casque Bluetooth branche, en ce moment ?**
 *
 * ## Pourquoi cet objet existe — 2026-09-10
 *
 * Signale par Jay : *« lorsque je branche mes ecouteurs Bluetooth et que
 * j'allume le BLE de NeoVibe ensuite, je n'entends plus la musique. »*
 *
 * Le BLE et l'audio Bluetooth classique **partagent la meme radio et la meme
 * antenne**. Notre scan tournait en `SCAN_MODE_LOW_LATENCY`, c'est-a-dire
 * **en continu, 100 % du temps**, et ne s'arretait jamais tant que le ping
 * etait allume. Une antenne occupee en permanence ne laisse plus de creneau
 * aux paquets audio : la musique hache, puis se tait.
 *
 * ## ⚠️ Cet objet CONSTATE, il ne decide de rien
 *
 * Regle « dissocier l'acquisition de l'usage » : il ne sait pas qui le lit, ni
 * ce qu'il en fera. Il ne touche ni au scan, ni a l'emission, ni au produit.
 * C'est [BleEngine] qui, le sachant, choisit son mode de scan.
 *
 * ## ⚠️ Pourquoi `AudioManager` et PAS `BluetoothProfile.getProfileConnectionState`
 *
 * La route Bluetooth demanderait la permission **`BLUETOOTH_CONNECT`**, que
 * l'app ne possede pas (verifie au manifeste le 2026-09-10) et qu'il faudrait
 * demander a l'utilisateur — pour une information de confort. `AudioManager`
 * repond a la meme question **sans aucune permission**, et voit en plus les
 * casques BLE Audio, que le profil A2DP ne connait pas.
 *
 * ## Ce que cet objet NE sait pas
 *
 * ⚠️ Il dit qu'un casque est **branche**, pas qu'il **joue**. Un casque connecte
 * et silencieux nous fera lever le pied pour rien. C'est assume : l'inverse —
 * savoir si du son sort — demanderait de surveiller les sessions audio des
 * autres applications, ce qui est bien plus intrusif que le probleme a resoudre.
 */
class AudioLink(
    private val context: Context,
    private val main: Handler,
    /** Appele quand la reponse CHANGE, jamais a chaque sonde. */
    private val onChange: () -> Unit,
) {
    private val audio: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    /**
     * Le dernier etat **publie**, pour ne reveiller le consommateur que sur un
     * vrai changement.
     *
     * ⚠️ Regle « qui consomme decide » : le cout d'une notification trop
     * frequente se regle ici, par une comparaison de valeurs — pas en aval.
     * Le rappel systeme part a chaque prise et chaque retrait d'un peripherique
     * audio, ecouteurs filaires et haut-parleur compris.
     */
    private var dernier = false

    private val rappel = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = revoir()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = revoir()
    }

    fun attach() {
        dernier = sonder()
        audio?.registerAudioDeviceCallback(rappel, main)
    }

    fun detach() {
        runCatching { audio?.unregisterAudioDeviceCallback(rappel) }
    }

    /** La reponse a jour, sans relire le systeme. */
    fun connecte(): Boolean = dernier

    private fun revoir() {
        val maintenant = sonder()
        if (maintenant == dernier) return
        dernier = maintenant
        onChange()
    }

    /**
     * ⚠️ **Les trois types comptent, et pour la meme raison.**
     *
     * - `BLUETOOTH_A2DP` : la musique, le cas de Jay ;
     * - `BLUETOOTH_SCO` : les appels et la plupart des kits mains libres ;
     * - `BLE_HEADSET` : les casques LE Audio, qui passent par la meme antenne
     *   que notre scan — donc le cas le PLUS sensible des trois.
     *
     * Un `runCatching` parce qu'un constructeur peut lever sur `getDevices` ;
     * en cas de doute on repond **non**, ce qui laisse le comportement d'avant.
     */
    private fun sonder(): Boolean = runCatching {
        val sorties = audio?.getDevices(AudioManager.GET_DEVICES_OUTPUTS) ?: return false
        sorties.any {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S &&
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    }.getOrDefault(false)
}
