package com.neovibe.neovibe

import com.neovibe.neovibe.ble.AdvertOnAir
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ce que ces tests defendent, et qui n'etait defendu par rien avant le
 * 2026-08-29 : **ce qu'on a demande a la radio n'est pas ce qu'elle crie.**
 */
class AdvertOnAirTest {

    private fun jetons(vararg s: String) = s.toList()

    // ------------------------------------------------------------------
    // Ne pas reecrire pour rien
    // ------------------------------------------------------------------

    @Test
    fun `un jeton confirme ne se reecrit pas`() {
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa", "bb"), repere = 10)
        assertTrue(air.besoinDEcrire(0, "aa"))
        air.noteEcrit(0, "aa")
        air.noteConfirme(0)
        assertFalse("un jeu confirme n'a rien a reecrire", air.besoinDEcrire(0, "aa"))
    }

    @Test
    fun `un ecrit en vol ne se redemande pas`() {
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa"), repere = 10)
        air.noteEcrit(0, "aa")
        assertFalse("l'ecrit est parti, on n'en empile pas un second", air.besoinDEcrire(0, "aa"))
    }

    @Test
    fun `redemander le meme creneau ne provoque aucun ecrit`() {
        // 🔴 Le gaspillage du 2026-08-29 : `emitNext` repasse toutes les 30 s
        // sur un contenu qui ne change que tous les quarts d'heure.
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa", "bb"), repere = 10)
        for (rang in 0..1) {
            air.noteEcrit(rang, jetons("aa", "bb")[rang])
            air.noteConfirme(rang)
        }
        air.noteDemande(jetons("aa", "bb"), repere = 10)
        assertFalse(air.besoinDEcrire(0, "aa"))
        assertFalse(air.besoinDEcrire(1, "bb"))
        assertEquals(10L, air.repereEnLAir)
    }

    // ------------------------------------------------------------------
    // Le refus, qui ne se voyait nulle part
    // ------------------------------------------------------------------

    @Test
    fun `un refus se compte et fait retomber le repere`() {
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa"), repere = 10)
        air.noteEcrit(0, "aa")
        air.noteConfirme(0)
        assertEquals(10L, air.repereEnLAir)

        air.noteDemande(jetons("bb"), repere = 11)
        air.noteEcrit(0, "bb")
        air.noteRefus(0)

        assertEquals(1, air.refus)
        assertEquals(
            "un jeu refuse ne sait plus ce qu'il porte : le repere ne vaut plus rien",
            AdvertOnAir.REPERE_INCONNU,
            air.repereEnLAir,
        )
        assertTrue("le tour suivant doit reecrire tout seul", air.besoinDEcrire(0, "bb"))
    }

    @Test
    fun `un refus ne fige pas la radio - le tour suivant repart`() {
        val air = AdvertOnAir()
        air.noteDemande(jetons("bb"), repere = 11)
        air.noteEcrit(0, "bb")
        air.noteRefus(0)

        air.noteDemande(jetons("bb"), repere = 11)
        assertTrue(air.besoinDEcrire(0, "bb"))
        air.noteEcrit(0, "bb")
        air.noteConfirme(0)
        assertEquals(11L, air.repereEnLAir)
    }

    // ------------------------------------------------------------------
    // Tout ou rien
    // ------------------------------------------------------------------

    @Test
    fun `un seul jeu a jour ne suffit pas`() {
        // ⚠️ Le cas exact de la matinee du 2026-08-29 : l'identifiant public
        // pouvait etre a jour pendant que le jeton d'AMI datait d'une heure.
        // Une moyenne aurait dit « a moitie bon » ; la moitie qui compte etait
        // fausse.
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa", "bb"), repere = 12)
        air.noteEcrit(0, "aa")
        air.noteConfirme(0)
        assertEquals(AdvertOnAir.REPERE_INCONNU, air.repereEnLAir)

        air.noteEcrit(1, "bb")
        air.noteConfirme(1)
        assertEquals(12L, air.repereEnLAir)
    }

    @Test
    fun `un plan qui retrecit ne bloque pas le repere`() {
        // 🔴 **Le cas que le contre-test a revele le 2026-08-29** : la premiere
        // version de ces tests ne le couvrait pas, et la ligne de `noteDemande`
        // qui le corrige pouvait etre retiree sans qu'aucun test ne tombe.
        //
        // Le plan passe de deux jetons a un quand « Croiser mes amis »
        // s'eteint. Sans oublier le rang disparu, les tailles ne concordent
        // plus jamais : le repere reste sur « on ne sait pas » pour toujours,
        // et aucun reecrit ne vient le debloquer — puisque le rang restant,
        // lui, est deja confirme.
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa", "bb"), repere = 10)
        for (rang in 0..1) {
            air.noteEcrit(rang, jetons("aa", "bb")[rang])
            air.noteConfirme(rang)
        }
        assertEquals(10L, air.repereEnLAir)

        air.noteDemande(jetons("aa"), repere = 10)
        assertFalse("le jeton restant est deja en l'air", air.besoinDEcrire(0, "aa"))
        assertEquals(
            "le jeu disparu ne doit pas figer le repere",
            10L,
            air.repereEnLAir,
        )
    }

    @Test
    fun `un nouveau creneau perime ce qui etait confirme`() {
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa"), repere = 10)
        air.noteEcrit(0, "aa")
        air.noteConfirme(0)

        air.noteDemande(jetons("zz"), repere = 11)
        assertEquals(
            "le jeu rayonne encore l'ancien jeton : ce n'est pas « a jour »",
            AdvertOnAir.REPERE_INCONNU,
            air.repereEnLAir,
        )
        assertTrue(air.besoinDEcrire(0, "zz"))
    }

    // ------------------------------------------------------------------
    // Le silence se constate
    // ------------------------------------------------------------------

    @Test
    fun `plus rien en l'air veut dire on ne sait pas`() {
        val air = AdvertOnAir()
        air.noteDemande(jetons("aa"), repere = 10)
        air.noteEcrit(0, "aa")
        air.noteConfirme(0)
        assertEquals(10L, air.repereEnLAir)

        air.oublie()
        assertEquals(AdvertOnAir.REPERE_INCONNU, air.repereEnLAir)
        assertTrue(air.besoinDEcrire(0, "aa"))
    }

    @Test
    fun `une confirmation sans ecrit n'invente rien`() {
        // Un rappel en retard, apres un oubli : il ne doit rien remettre en
        // l'air. « Je ne sais pas » ne se repare pas tout seul.
        val air = AdvertOnAir()
        air.noteConfirme(0)
        assertEquals(AdvertOnAir.REPERE_INCONNU, air.repereEnLAir)
    }

    @Test
    fun `l'hexadecimal est celui de la table de reconnaissance`() {
        assertEquals("00010aff", AdvertOnAir.hex(byteArrayOf(0, 1, 10, -1)))
    }
}
