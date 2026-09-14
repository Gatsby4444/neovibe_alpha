package com.neovibe.neovibe

import com.neovibe.neovibe.ble.SlotAlarm
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ce que ces tests defendent : **la sonnerie doit tomber DANS le creneau
 * suivant, jamais sur sa frontiere.**
 *
 * Le defaut vise n'est pas une exception, c'est un quart d'heure
 * d'invisibilite par creneau. Une alarme qui part une milliseconde trop tot
 * laisse `now / slotMillis` sur l'ancien creneau : `emitNext` reecrit alors le
 * jeton qu'on vient de quitter, et personne en face ne reconnait plus rien —
 * sans qu'aucune erreur soit levee, ni ici, ni sur l'appareil.
 */
class SlotAlarmTest {

    private val creneau = 900_000L // 15 minutes, la valeur du projet

    @Test
    fun `sonne dans le creneau suivant, pas sur sa frontiere`() {
        val maintenant = 1_000_000_000_000L
        val vise = SlotAlarm.prochaineFrontiere(maintenant, creneau)
        val frontiere = ((maintenant / creneau) + 1) * creneau

        // 🔴 **Le contre-test de ce fichier.** Retirer `MARGE` fait tomber
        // cette ligne, et elle seule : les deux suivantes resteraient vertes.
        assertTrue(
            "la sonnerie doit tomber APRES la frontiere, pas dessus",
            vise > frontiere,
        )
        assertEquals(
            "et elle doit rester dans le creneau suivant",
            (maintenant / creneau) + 1,
            vise / creneau,
        )
    }

    @Test
    fun `appele pile sur une frontiere, vise la suivante et pas celle-ci`() {
        // Le cas qui produirait une boucle de sonneries a delai nul.
        val frontiere = 1_000_000L * creneau
        val vise = SlotAlarm.prochaineFrontiere(frontiere, creneau)

        assertTrue("la sonnerie doit etre dans le futur", vise > frontiere)
        assertEquals(1_000_001L, vise / creneau)
    }

    @Test
    fun `l'attente ne depasse jamais une duree de creneau`() {
        // Sinon un jeton resterait fige plus longtemps que la fenetre de
        // tolerance de `RecognitionTable.match`, qui vaut un creneau.
        for (decalage in 0 until 20) {
            val maintenant = 1_000_000L * creneau + decalage * 45_000L
            val attente = SlotAlarm.prochaineFrontiere(maintenant, creneau) - maintenant
            assertTrue("attente positive", attente > 0)
            assertTrue(
                "attente de $attente ms pour un creneau de $creneau ms",
                attente <= creneau + SlotAlarm.MARGE,
            )
        }
    }

    // ------------------------------------------------------------------
    // La sonnerie avalee — nuit du 2026-09-14
    // ------------------------------------------------------------------

    @Test
    fun `en retard n'est pas perdue - les 10 minutes de la nuit du 2026-09-14 sont absorbees`() {
        val vise = 1_000_000L * creneau
        // Retards releves dans le carnet : 41 s a 644 s.
        for (retard in longArrayOf(0L, 41_502L, 255_339L, 644_333L, creneau)) {
            assertTrue(
                "un retard de $retard ms n'est qu'un retard",
                !SlotAlarm.estPerdue(vise + retard, vise, creneau),
            )
        }
    }

    @Test
    fun `un creneau entier apres l'echeance, elle est perdue`() {
        val vise = 1_000_000L * creneau
        // 🔴 **Le contre-test.** Remplacer `>` par `>=` ou retirer la
        // comparaison fait tomber l'un des deux, jamais les deux.
        assertTrue(!SlotAlarm.estPerdue(vise + creneau, vise, creneau))
        assertTrue(SlotAlarm.estPerdue(vise + creneau + 1, vise, creneau))
    }

    @Test
    fun `sans echeance visee, rien n'est jamais perdu`() {
        // `vise == 0` = reveil desarme : `veille()` ne doit rien reposer, sinon
        // un service qui a coupe sa radio se remettrait a sonner tout seul.
        assertTrue(!SlotAlarm.estPerdue(Long.MAX_VALUE / 2, 0L, creneau))
    }
}
