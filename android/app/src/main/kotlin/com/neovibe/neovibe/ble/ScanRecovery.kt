package com.neovibe.neovibe.ble

import android.bluetooth.le.ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_INTERNAL_ERROR
import android.bluetooth.le.ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES

/**
 * **Quand reprendre l'ecoute apres un refus d'Android** — une decision pure,
 * sans radio ni horloge, pour pouvoir la tester.
 *
 * ## 🔴 Ce que le diagnostic du 2026-09-23 a montre
 *
 * A 10:53, une minute apres l'extinction de l'ecran, le moteur arrete puis
 * relance le scan pour passer au rythme econome ([BleEngine.modeDeScan]).
 * Android refuse la relance (`SCAN_FAILED_APPLICATION_REGISTRATION_FAILED`).
 * **Aucune reprise n'existait pour ce code** : le telephone de Jay est reste
 * sourd plus d'une heure, en continuant d'emettre — donc visible des autres,
 * incapable de les voir, sans que rien ne le dise. Le lien avec la relance
 * « ecran eteint » est **probable, pas prouve** (deux secondes d'ecart).
 *
 * ## Ce qui reprend seul, et ce qui ne reprend pas
 *
 * Trois refus sont des etats **passagers** de la pile Bluetooth : un
 * enregistrement refuse, une erreur interne, des ressources saturees par
 * d'autres applications. Ils se reessaient. `FEATURE_UNSUPPORTED` est une
 * propriete de l'appareil : le reessayer ne changerait rien. `ALREADY_STARTED`
 * et `SCANNING_TOO_FREQUENTLY` ont deja leur propre chemin dans le moteur.
 *
 * ## Le rythme : de plus en plus espace, jamais abandonne
 *
 * ⚠️ **Le quota d'Android** : quelques `startScan` par tranche de 30 s, au-dela
 * c'est `SCANNING_TOO_FREQUENTLY`. Le premier essai a 5 s et le second a 30 s
 * n'en consomment que deux. Ensuite 2 min, puis toutes les 5 min **tant que le
 * ping est voulu** : abandonner, c'est redevenir sourd pour la journee — le
 * defaut exact qu'on corrige.
 */
object ScanRecovery {

    /** Les delais successifs ; le dernier se repete. */
    val DELAIS_MS = longArrayOf(5_000L, 30_000L, 120_000L, 300_000L)

    /** Ce refus se reessaie-t-il seul ? */
    fun reprendSeul(errorCode: Int): Boolean = when (errorCode) {
        SCAN_FAILED_APPLICATION_REGISTRATION_FAILED,
        SCAN_FAILED_INTERNAL_ERROR,
        SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> true
        else -> false
    }

    /**
     * Le delai avant la tentative suivante, [refusConsecutifs] valant 1 apres
     * le premier refus.
     */
    fun delaiApres(refusConsecutifs: Int): Long {
        val i = (refusConsecutifs - 1).coerceIn(0, DELAIS_MS.size - 1)
        return DELAIS_MS[i]
    }
}
