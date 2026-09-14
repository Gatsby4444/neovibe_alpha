package com.neovibe.neovibe.ble

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat

/**
 * **L'energie du telephone, vue par le carnet.**
 *
 * ## Le trou que ce fichier bouche — nuit du 2026-09-14
 *
 * Le carnet de cette nuit (`dev_reports` `8eb6d161…`) disait « le Bluetooth
 * s'est eteint a 02:31 et rallume a 07:18 », « l'alarme de 02:15 n'a jamais
 * sonne », « memoire basse quatre fois en quatre secondes » — et Jay dormait.
 * Il disait aussi, apres coup, que la batterie externe s'etait arretee en
 * cours de nuit. **Rien de tout ca n'etait dans le carnet** : ni le chargeur,
 * ni le niveau de batterie, ni l'entree en sommeil profond, ni l'economie
 * d'energie. On ne pouvait donc pas dire si le telephone avait coupe le
 * Bluetooth parce qu'il passait sur batterie, ou pour une autre raison.
 *
 * Ce sont pourtant des signaux qu'Android **envoie** ; il suffit de les
 * ecouter. Ce fichier les ecoute et les remet a [ServiceJournal] sous forme
 * d'evenements (« chargeur debranche », « ecran eteint », « veille profonde :
 * oui »…), chacun accompagne du [Energie.resume] du moment.
 *
 * ## Ce qu'il ne fait pas
 *
 * Il ne decide de rien : il ne coupe pas la radio quand la batterie baisse, il
 * ne change aucune cadence. C'est un instrument. Le jour ou une regle
 * d'economie sera voulue, elle vivra ailleurs et lira ces memes signaux.
 *
 * ⚠️ **Enregistre a l'execution, jamais au manifeste** : `ACTION_SCREEN_ON`,
 * `ACTION_POWER_CONNECTED` et les autres ne se declarent pas au manifeste, et
 * de toute facon ces lignes n'ont de sens que tant que le service vit.
 */
class EnergyWatcher(
    private val context: Context,
    private val note: (evenement: String, detail: String) -> Unit,
) {
    private var enregistre = false

    private val recepteur = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            val pm = context.getSystemService(PowerManager::class.java)
            val evenement = libelle(
                action,
                veilleProfonde = pm?.isDeviceIdleMode == true,
                veilleLegere = Energie.veilleLegere(pm),
                economie = pm?.isPowerSaveMode == true,
            ) ?: return
            note(evenement, Energie.resume(context))
        }
    }

    fun attach() {
        if (enregistre) return
        val filtre = IntentFilter().apply { ACTIONS.forEach { addAction(it) } }
        // Les diffusions du systeme arrivent a un recepteur non exporte : c'est
        // le cas documente, et le seul qu'on ecoute ici.
        runCatching {
            ContextCompat.registerReceiver(context, recepteur, filtre, ContextCompat.RECEIVER_NOT_EXPORTED)
            enregistre = true
        }
    }

    fun detach() {
        if (!enregistre) return
        runCatching { context.unregisterReceiver(recepteur) }
        enregistre = false
    }

    companion object {
        // `by lazy` : `Build.VERSION` ne se lit qu'a l'enregistrement, pas au
        // chargement de la classe — les tests JVM appellent [libelle] sans Android.
        private val ACTIONS by lazy {
            buildList {
                add(Intent.ACTION_POWER_CONNECTED)
                add(Intent.ACTION_POWER_DISCONNECTED)
                add(Intent.ACTION_SCREEN_ON)
                add(Intent.ACTION_SCREEN_OFF)
                add(Intent.ACTION_BATTERY_LOW)
                add(Intent.ACTION_BATTERY_OKAY)
                add(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                add(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                if (Build.VERSION.SDK_INT >= 33) add(ACTION_VEILLE_LEGERE)
            }
        }

        /** `PowerManager.ACTION_DEVICE_LIGHT_IDLE_MODE_CHANGED`, Android 13+. En clair pour que [libelle] reste pur. */
        const val ACTION_VEILLE_LEGERE = "android.os.action.LIGHT_DEVICE_IDLE_MODE_CHANGED"

        /**
         * L'evenement a ecrire pour une diffusion recue, ou `null` si elle ne
         * nous concerne pas. Pure : c'est la table qui traduit Android en
         * francais lisible, et c'est elle qui est eprouvee (`EnergyWatcherTest`).
         */
        fun libelle(
            action: String,
            veilleProfonde: Boolean,
            veilleLegere: Boolean,
            economie: Boolean,
        ): String? = when (action) {
            Intent.ACTION_POWER_CONNECTED -> "chargeur branche"
            Intent.ACTION_POWER_DISCONNECTED -> "chargeur debranche"
            Intent.ACTION_SCREEN_ON -> "ecran allume"
            Intent.ACTION_SCREEN_OFF -> "ecran eteint"
            Intent.ACTION_BATTERY_LOW -> "batterie faible"
            Intent.ACTION_BATTERY_OKAY -> "batterie ok"
            PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED ->
                "veille profonde : ${if (veilleProfonde) "oui" else "non"}"
            ACTION_VEILLE_LEGERE ->
                "veille legere : ${if (veilleLegere) "oui" else "non"}"
            PowerManager.ACTION_POWER_SAVE_MODE_CHANGED ->
                "economie d'energie : ${if (economie) "oui" else "non"}"
            else -> null
        }
    }
}

/**
 * L'etat d'energie du moment, en une ligne — pour accompagner les evenements
 * du carnet qui en dependent (creation, radio, alarme, memoire basse).
 *
 * Forme : `batt=57% chargeur=non eco=non veille=profonde ecran=eteint`.
 * Rien d'autre que des etats du telephone : aucun identifiant.
 */
object Energie {

    fun resume(context: Context): String {
        val batterie = runCatching {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull()
        val niveau = batterie?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val echelle = batterie?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val branche = (batterie?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val pm = context.getSystemService(PowerManager::class.java)
        return ligne(
            pourcent = if (niveau >= 0 && echelle > 0) niveau * 100 / echelle else -1,
            chargeur = branche,
            economie = pm?.isPowerSaveMode == true,
            veilleProfonde = pm?.isDeviceIdleMode == true,
            veilleLegere = veilleLegere(pm),
            ecranAllume = pm?.isInteractive != false,
        )
    }

    /** `isDeviceLightIdleMode` n'existe qu'a partir d'Android 13. */
    fun veilleLegere(pm: PowerManager?): Boolean =
        Build.VERSION.SDK_INT >= 33 && pm?.isDeviceLightIdleMode == true

    /** Pure : la mise en forme, eprouvee a part. */
    fun ligne(
        pourcent: Int,
        chargeur: Boolean,
        economie: Boolean,
        veilleProfonde: Boolean,
        veilleLegere: Boolean,
        ecranAllume: Boolean,
    ): String {
        val veille = when {
            veilleProfonde -> "profonde"
            veilleLegere -> "legere"
            else -> "non"
        }
        val batt = if (pourcent < 0) "?" else "$pourcent%"
        return "batt=$batt chargeur=${ouiNon(chargeur)} eco=${ouiNon(economie)} " +
            "veille=$veille ecran=${if (ecranAllume) "allume" else "eteint"}"
    }

    private fun ouiNon(b: Boolean) = if (b) "oui" else "non"
}
