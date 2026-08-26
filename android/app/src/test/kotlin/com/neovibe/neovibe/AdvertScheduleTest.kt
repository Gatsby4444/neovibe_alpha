package com.neovibe.neovibe

import com.neovibe.neovibe.ble.AdvertSchedule
import com.neovibe.neovibe.ble.BleConstants
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Ce que ces tests protegent : **le creneau entier, pas un jeton a la fois**.
 *
 * Le service emettait un seul jeton par tour de cycle, toutes les 400 ms. Avec
 * dix amis, le jeton de chacun n'etait donc en l'air que 10 % du temps :
 * quelqu'un qu'on croise trois secondes dans un couloir pouvait n'etre **jamais**
 * vu, et le defaut s'aggravait avec le nombre d'amis. Rien ne le levait.
 *
 * `tokensAt` rend tout le creneau d'un coup, ce qui permet au moteur d'emettre
 * les jetons **simultanement**. L'invariant a tenir est donc celui-ci : le
 * creneau entier doit contenir exactement ce que le curseur aurait fini par
 * emettre, dans le meme ordre et avec les memes types.
 */
class AdvertScheduleTest {

    private val slotMillis = 900_000L
    private val tokenLength = 16

    /** Un plan de [slots] creneaux et [perSlot] jetons, aux octets previsibles. */
    private fun plan(
        fromSlot: Long,
        slots: Int,
        perSlot: Int,
        types: ByteArray = ByteArray(slots * perSlot) { BleConstants.TYPE_FRIEND },
    ): AdvertSchedule {
        val tokens = ByteArray(slots * perSlot * tokenLength)
        for (i in 0 until slots * perSlot) {
            for (b in 0 until tokenLength) {
                tokens[i * tokenLength + b] = (i + b).toByte()
            }
        }
        return AdvertSchedule(fromSlot, slotMillis, slots, perSlot, tokens, tokenLength, types)
    }

    @Test
    fun `le creneau entier contient ce que le curseur aurait emis`() {
        val from = 1000L
        val p = plan(from, slots = 3, perSlot = 4)
        val now = from * slotMillis + 1234

        val (jetons, leursTypes) = p.tokensAt(now)!!
        assertEquals("un jeton par ami du creneau", 4, jetons.size)
        assertEquals(4, leursTypes.size)

        // L'invariant : rang i du creneau == ce que le curseur i aurait rendu.
        for (i in 0 until 4) {
            assertArrayEquals(
                "le rang $i doit valoir le jeton du curseur $i",
                p.tokenAt(now, i),
                jetons[i],
            )
            assertEquals(p.typeAt(now, i), leursTypes[i])
        }
    }

    @Test
    fun `deux creneaux consecutifs ne partagent aucun jeton`() {
        // Sinon le pistage d'un creneau a l'autre redeviendrait trivial.
        val from = 1000L
        val p = plan(from, slots = 2, perSlot = 2)
        val a = p.tokensAt(from * slotMillis)!!.first.map { it.toList() }
        val b = p.tokensAt((from + 1) * slotMillis)!!.first.map { it.toList() }
        assertEquals(0, a.intersect(b.toSet()).size)
    }

    @Test
    fun `hors du plan, on se TAIT plutot que de rejouer l'ancien`() {
        // Meme reponse que `tokenAt` : reemettre un jeton perime ne se voit pas,
        // ne leve rien, et laisse croire a une radio saine alors que plus
        // personne ne nous reconnait.
        val from = 1000L
        val p = plan(from, slots = 2, perSlot = 2)
        assertNull(p.tokensAt((from + 2) * slotMillis))
        assertNull(p.tokensAt((from - 1) * slotMillis))
    }

    @Test
    fun `les types suivent les jetons, ils ne se deduisent pas`() {
        // Lequel des jetons est l'identifiant public est une regle produit :
        // elle descend du Dart et ne doit jamais etre reconstituee ici.
        val from = 1000L
        val types = byteArrayOf(
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
        )
        val p = plan(from, slots = 2, perSlot = 2, types = types)
        val (_, t0) = p.tokensAt(from * slotMillis)!!
        assertEquals(BleConstants.TYPE_PUBLIC, t0[0])
        assertEquals(BleConstants.TYPE_FRIEND, t0[1])
    }

    @Test
    fun `un plan tronque rend null au lieu de lire hors du tampon`() {
        // Un depassement silencieux ferait crier des octets voisins - donc un
        // identifiant que personne n'attend, indiscernable d'une radio muette.
        val tokens = ByteArray(tokenLength) // un seul jeton pour deux annonces
        val p = AdvertSchedule(
            1000L, slotMillis, 1, 2, tokens, tokenLength,
            ByteArray(2) { BleConstants.TYPE_FRIEND },
        )
        assertNull(p.tokensAt(1000L * slotMillis))
    }
}
