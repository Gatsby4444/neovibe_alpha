package com.neovibe.neovibe

import com.neovibe.neovibe.ble.NativeSighting
import com.neovibe.neovibe.ble.RecognitionTable
import com.neovibe.neovibe.ble.SightingBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Ce que ces tests protegent : **la reconnaissance sans le Dart**.
 *
 * Ce code tourne quand l'interface est morte, donc quand personne ne regarde et
 * qu'aucune erreur ne remonterait. Il ne peut pas etre valide "a l'usage" — un
 * defaut ici se manifeste par « je ne le vois plus », des semaines plus tard.
 * D'ou une logique volontairement PURE (aucune dependance Android), pour qu'elle
 * soit verifiable sur la JVM.
 */
class SightingBookTest {

    private val slotMillis = 900_000L // 15 min

    /** Fabrique un tampon a plat : slotCount creneaux x perSlot amis. */
    private fun tokens(fromSlot: Long, slotCount: Int, perSlot: Int): ByteArray {
        val out = ByteArray(slotCount * perSlot * 16)
        var pos = 0
        for (s in 0 until slotCount) {
            for (i in 0 until perSlot) {
                // Un motif unique par (creneau, ami), comme le ferait un HMAC.
                out[pos] = (fromSlot + s).toByte()
                out[pos + 1] = i.toByte()
                out[pos + 2] = ((fromSlot + s) shr 8).toByte()
                pos += 16
            }
        }
        return out
    }

    private fun tokenOf(fromSlot: Long, slot: Long, index: Int): ByteArray {
        val t = ByteArray(16)
        t[0] = slot.toByte()
        t[1] = index.toByte()
        t[2] = (slot shr 8).toByte()
        return t
    }

    private fun table(fromSlot: Long, slotCount: Int = 4, perSlot: Int = 3) =
        RecognitionTable(
            tableId = 7,
            fromSlot = fromSlot,
            slotMillis = slotMillis,
            slotCount = slotCount,
            perSlot = perSlot,
            tokens = tokens(fromSlot, slotCount, perSlot),
            tokenLength = 16,
        )

    @Test
    fun `un jeton attendu au creneau courant est reconnu`() {
        val creneau = 2_137_456L
        val t = table(creneau)
        val maintenant = creneau * slotMillis + 1000

        assertEquals(0, t.match(tokenOf(creneau, creneau, 0), maintenant))
        assertEquals(2, t.match(tokenOf(creneau, creneau, 2), maintenant))
    }

    @Test
    fun `la tolerance couvre un creneau de part et d'autre`() {
        // Deux telephones n'ont jamais exactement la meme heure.
        val creneau = 2_137_456L
        val t = table(creneau - 1, slotCount = 4)
        val maintenant = creneau * slotMillis + 1000

        assertEquals(1, t.match(tokenOf(creneau - 1, creneau - 1, 1), maintenant))
        assertEquals(1, t.match(tokenOf(creneau - 1, creneau + 1, 1), maintenant))
    }

    @Test
    fun `un jeton REJOUE plus tard est refuse`() {
        // ⚠️ La propriete de securite : sans la fenetre de creneau, il suffirait
        // d'enregistrer une annonce le matin pour fabriquer un croisement le
        // soir. La table couvre 12 h de jetons — c'est l'HEURE qui tranche, pas
        // la presence du jeton dans la table.
        val creneau = 2_137_456L
        val t = table(creneau, slotCount = 48)
        val jeton = tokenOf(creneau, creneau, 0)

        assertEquals(0, t.match(jeton, creneau * slotMillis))
        assertNull(t.match(jeton, (creneau + 5) * slotMillis))
        assertNull(t.match(jeton, (creneau + 40) * slotMillis))
    }

    @Test
    fun `un jeton inconnu ne dit rien`() {
        val creneau = 2_137_456L
        val t = table(creneau)
        assertNull(t.match(ByteArray(16) { 0x5A }, creneau * slotMillis))
    }

    @Test
    fun `la table ne contient aucune identite, seulement des rangs`() {
        // Elle est construite de jetons et rend des entiers. Rien d'autre n'y
        // entre : un vidage memoire du service ne dit pas qui sont les amis.
        val creneau = 2_137_456L
        val t = table(creneau, slotCount = 4, perSlot = 3)
        assertEquals(12, t.size)
        assertEquals(7, t.tableId)
    }

    @Test
    fun `un ami immobile ne produit qu'un constat par creneau`() {
        val buffer = SightingBuffer()
        repeat(9000) {
            buffer.note(NativeSighting(1, 3, 2_137_456L, -70, -59))
        }
        assertEquals(1, buffer.size)
    }

    @Test
    fun `on garde le MEILLEUR signal du creneau`() {
        val buffer = SightingBuffer()
        buffer.note(NativeSighting(1, 3, 2_137_456L, -90, -59))
        buffer.note(NativeSighting(1, 3, 2_137_456L, -55, -59))
        buffer.note(NativeSighting(1, 3, 2_137_456L, -80, -59))

        val out = buffer.drain()
        assertEquals(1, out.size)
        assertEquals(-55, out.first().rssi)
    }

    @Test
    fun `le creneau suivant produit un nouveau constat`() {
        val buffer = SightingBuffer()
        buffer.note(NativeSighting(1, 3, 2_137_456L, -70, -59))
        buffer.note(NativeSighting(1, 3, 2_137_457L, -70, -59))
        assertEquals(2, buffer.size)
    }

    @Test
    fun `deux amis au meme creneau font deux constats`() {
        val buffer = SightingBuffer()
        buffer.note(NativeSighting(1, 3, 2_137_456L, -70, -59))
        buffer.note(NativeSighting(1, 4, 2_137_456L, -70, -59))
        assertEquals(2, buffer.size)
    }

    @Test
    fun `le tampon est borne`() {
        // Une memoire non bornee dans un service qui vit des jours est une fuite.
        val buffer = SightingBuffer(maxEntries = 10)
        for (i in 0 until 100) {
            buffer.note(NativeSighting(1, i, 2_137_456L, -70, -59))
        }
        assertEquals(10, buffer.size)
    }

    @Test
    fun `drain rend tout et vide`() {
        val buffer = SightingBuffer()
        buffer.note(NativeSighting(1, 3, 2_137_456L, -70, -59))
        buffer.note(NativeSighting(1, 4, 2_137_456L, -60, -59))

        assertEquals(2, buffer.drain().size)
        assertEquals(0, buffer.size)
        assertEquals(0, buffer.drain().size)
    }

    // ------------------------------------------------------------------
    // Le tampon plein — defaut du 2026-08-31
    // ------------------------------------------------------------------

    /**
     * 🔴 **Le contre-test du defaut trouve a l'audit du 2026-08-31.**
     *
     * Au plein, `note` faisait `return` : tout nouveau constat etait ignore et
     * les anciens conserves. C'est l'inverse de ce qu'il faut pour une fenetre
     * glissante.
     *
     * 500 entrees valent ami x creneau. Une nuit de douze heures fait
     * 48 creneaux : le plafond est atteint des **onze amis**, et ce sont alors
     * les heures les plus RECENTES qui etaient perdues — chez les utilisateurs
     * qui en ont le plus, et sans que rien ne le signale.
     *
     * ⚠️ Remettre le `return` doit faire tomber ce test.
     */
    @Test
    fun `au plein, c'est le constat le plus VIEUX qui part`() {
        val buffer = SightingBuffer(maxEntries = 3)
        // Trois creneaux consecutifs, meme ami.
        for (slot in 10L..12L) {
            buffer.note(NativeSighting(tableId = 1, friendIndex = 0, slot = slot, rssi = -60, txPower = 0))
        }
        assertEquals(3, buffer.size)

        // Le quatrieme arrive alors que c'est plein.
        buffer.note(NativeSighting(tableId = 1, friendIndex = 0, slot = 13L, rssi = -60, txPower = 0))

        val restants = buffer.drain().map { it.slot }.sorted()
        assertEquals(
            "le creneau 10 part, le 13 entre : on garde la fenetre RECENTE",
            listOf(11L, 12L, 13L),
            restants,
        )
    }

    @Test
    fun `au plein, un constat plus vieux que tout le reste est ignore`() {
        val buffer = SightingBuffer(maxEntries = 2)
        buffer.note(NativeSighting(tableId = 1, friendIndex = 0, slot = 20L, rssi = -60, txPower = 0))
        buffer.note(NativeSighting(tableId = 1, friendIndex = 0, slot = 21L, rssi = -60, txPower = 0))

        // Un retardataire du creneau 5 : le jeter ne gagne rien, on prefere ce
        // qui est deja la.
        buffer.note(NativeSighting(tableId = 1, friendIndex = 0, slot = 5L, rssi = -60, txPower = 0))

        val restants = buffer.drain().map { it.slot }.sorted()
        assertEquals(listOf(20L, 21L), restants)
    }
}
