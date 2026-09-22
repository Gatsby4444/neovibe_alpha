package com.neovibe.neovibe

import com.neovibe.neovibe.ble.Energie
import com.neovibe.neovibe.ble.EnergyWatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Ce que ces tests defendent : **la ligne d'energie du carnet dit vrai, et
 * chaque signal d'Android a un nom francais stable** — c'est ce nom que la
 * lecture Dart compte (`service_journal_reading.dart`). Le renommer ici sans
 * le renommer la-bas rendrait un compteur muet, sans erreur nulle part.
 */
class EnergyWatcherTest {

    @Test
    fun `la ligne d'energie porte les six etats, dans un ordre fixe`() {
        assertEquals(
            "batt=57% chargeur=non eco=non veille=profonde ecran=eteint exempt=non",
            Energie.ligne(57, chargeur = false, economie = false, veilleProfonde = true, veilleLegere = true, ecranAllume = false, exempt = false),
        )
        assertEquals(
            "batt=100% chargeur=oui eco=oui veille=legere ecran=allume exempt=oui",
            Energie.ligne(100, chargeur = true, economie = true, veilleProfonde = false, veilleLegere = true, ecranAllume = true, exempt = true),
        )
        // Niveau inconnu : un « ? », jamais un faux zero (regle « lire la
        // mesure, pas l'instrument »).
        assertEquals(
            "batt=? chargeur=non eco=non veille=non ecran=allume exempt=non",
            Energie.ligne(-1, chargeur = false, economie = false, veilleProfonde = false, veilleLegere = false, ecranAllume = true, exempt = false),
        )
    }

    @Test
    fun `chaque signal a son libelle, et un signal etranger n'en a pas`() {
        fun l(action: String, profonde: Boolean = false, legere: Boolean = false, eco: Boolean = false) =
            EnergyWatcher.libelle(action, profonde, legere, eco)

        assertEquals("chargeur branche", l("android.intent.action.ACTION_POWER_CONNECTED"))
        assertEquals("chargeur debranche", l("android.intent.action.ACTION_POWER_DISCONNECTED"))
        assertEquals("ecran allume", l("android.intent.action.SCREEN_ON"))
        assertEquals("ecran eteint", l("android.intent.action.SCREEN_OFF"))
        assertEquals("batterie faible", l("android.intent.action.BATTERY_LOW"))
        assertEquals("batterie ok", l("android.intent.action.BATTERY_OKAY"))
        assertEquals("veille profonde : oui", l("android.os.action.DEVICE_IDLE_MODE_CHANGED", profonde = true))
        assertEquals("veille profonde : non", l("android.os.action.DEVICE_IDLE_MODE_CHANGED"))
        assertEquals("veille legere : oui", l(EnergyWatcher.ACTION_VEILLE_LEGERE, legere = true))
        assertEquals("economie d'energie : oui", l("android.os.action.POWER_SAVE_MODE_CHANGED", eco = true))
        assertEquals("economie d'energie : non", l("android.os.action.POWER_SAVE_MODE_CHANGED"))
        assertNull(l("android.intent.action.AIRPLANE_MODE"))
    }
}
