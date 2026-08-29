package com.neovibe.neovibe

import com.neovibe.neovibe.ble.AdvertSchedule
import com.neovibe.neovibe.ble.BleConstants
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Ce que ces tests protegent : **on persiste les jetons d'AMIS, jamais
 * l'identifiant public du ping.**
 *
 * ## Le choix de Jay, 2026-08-28
 *
 * Le plan d'emission vivait en memoire seulement : quand Android recuperait le
 * processus, le croisement app fermee s'arretait jusqu'a ce qu'on rouvre l'app.
 * Il est desormais ecrit sur le disque — **mais pas en entier**.
 *
 * | | Ecrit ? | Pourquoi |
 * |---|---|---|
 * | jetons de paire (amis) | oui | c'est eux qui font le croisement app fermee |
 * | identifiant PUBLIC | **non** | il repart de zero a chaque lancement, et c'est ce qui empeche de relier deux sessions de decouverte |
 *
 * ⚠️ **Ce test est la seule chose qui empeche l'identifiant public de finir sur
 * le disque.** Le defaut serait totalement silencieux : le fichier
 * fonctionnerait, l'appareil crierait juste, et la propriete perdue ne se
 * verrait nulle part.
 */
class PlanPersistenceTest {

    private val slotMillis = 900_000L
    private val tokenLength = 16

    /**
     * Un plan « comme en production » : par creneau, l'identifiant PUBLIC en
     * premier, puis un jeton par ami.
     */
    private fun planMixte(slots: Int, amis: Int): AdvertSchedule {
        val perSlot = amis + 1
        val tokens = ByteArray(slots * perSlot * tokenLength)
        val types = ByteArray(slots * perSlot)
        for (s in 0 until slots) {
            for (i in 0 until perSlot) {
                val rang = s * perSlot + i
                types[rang] = if (i == 0) BleConstants.TYPE_PUBLIC else BleConstants.TYPE_FRIEND
                for (b in 0 until tokenLength) {
                    // Le premier octet dit d'ou vient le jeton : 0 = public.
                    tokens[rang * tokenLength + b] = if (b == 0) i.toByte() else (s + b).toByte()
                }
            }
        }
        return AdvertSchedule(
            fromSlot = 100,
            slotMillis = slotMillis,
            slotCount = slots,
            perSlot = perSlot,
            tokens = tokens,
            tokenLength = tokenLength,
            types = types,
        )
    }

    @Test
    fun `l identifiant public ne survit pas a la persistance`() {
        val amis = requireNotNull(planMixte(slots = 4, amis = 2).friendsOnly())

        assertEquals("deux amis par creneau, plus d'identifiant public", 2, amis.cycleLength)
        assertEquals(4 * 2 * tokenLength, amis.rawTokens.size)

        // ⚠️ Le premier octet vaut 0 pour l'identifiant public. Aucun ne doit
        // subsister : c'est la propriete que ce fichier existe pour tenir.
        for (rang in 0 until 4 * 2) {
            assertEquals(
                "aucun jeton public ne doit rester (rang $rang)",
                true,
                amis.rawTokens[rang * tokenLength].toInt() != 0,
            )
        }
    }

    @Test
    fun `les jetons d amis gardent leur ordre et leur valeur`() {
        val complet = planMixte(slots = 3, amis = 2)
        val amis = requireNotNull(complet.friendsOnly())

        // Ce que le plan complet crierait pour le creneau 101, sans le public.
        val attendu = complet.tokensAt(101 * slotMillis)!!.first.drop(1)
        val obtenu = amis.tokensAt(101 * slotMillis)!!.first

        assertEquals(2, obtenu.size)
        for (i in 0 until 2) {
            assertArrayEquals(
                "le jeton d'un ami doit traverser la persistance a l'identique",
                attendu[i],
                obtenu[i],
            )
        }
    }

    @Test
    fun `tout ce qui reste est de type AMI`() {
        val amis = requireNotNull(planMixte(slots = 2, amis = 3).friendsOnly())
        // typeAt a ete supprime le 2026-08-29 : on lit les types la ou ils
        // partent vraiment a la radio, c est-a-dire dans le creneau entier.
        val (_, types) = requireNotNull(amis.tokensAt(100 * slotMillis))
        assertEquals(amis.cycleLength, types.size)
        for (t in types) assertEquals(BleConstants.TYPE_FRIEND, t)
    }

    @Test
    fun `un plan sans aucun ami ne donne RIEN a persister`() {
        // ⚠️ Le cas de quelqu'un qui n'a pas encore d'amis : il n'y a rien a
        // reprendre app fermee, et un fichier ne portant que l'identifiant
        // public serait exactement ce qu'on refuse d'ecrire.
        assertNull(planMixte(slots = 4, amis = 0).friendsOnly())
    }

    @Test
    fun `un plan vide ne donne rien non plus`() {
        val vide = AdvertSchedule(
            fromSlot = 0,
            slotMillis = slotMillis,
            slotCount = 0,
            perSlot = 0,
            tokens = ByteArray(0),
            tokenLength = tokenLength,
            types = ByteArray(0),
        )
        assertNull(vide.friendsOnly())
    }

    @Test
    fun `le plan persiste couvre les memes creneaux que l original`() {
        val amis = requireNotNull(planMixte(slots = 4, amis = 1).friendsOnly())
        assertNotNull(amis.tokensAt(100 * slotMillis))
        assertNotNull(amis.tokensAt(103 * slotMillis))
        assertNull(
            "un plan perime doit rendre null, jamais « au mieux »",
            amis.tokensAt(104 * slotMillis),
        )
    }
}
