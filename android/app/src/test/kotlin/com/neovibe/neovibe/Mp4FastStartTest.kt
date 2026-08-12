package com.neovibe.neovibe

import java.io.File
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Vérifie que déplacer l'index d'un MP4 ne casse pas le fichier.
 *
 * L'assertion qui compte n'est pas « `moov` est passé devant » — c'est **« les
 * décalages pointent toujours sur les mêmes octets »**. Un index déplacé sans
 * correction des décalages produit un fichier de taille identique, à la
 * structure valide, et **illisible** : exactement le genre de panne qui ne se
 * verrait qu'au test de Jay.
 */
class Mp4FastStartTest {

    /** 40 octets reconnaissables, sans motif qui puisse passer pour une boîte. */
    private val payload = ByteArray(40) { (it + 1).toByte() }

    @Test
    fun `l index passe devant et les decalages suivent`() {
        val file = buildMovie(moovLast = true)
        val before = file.readBytes()
        val oldOffsets = chunkOffsets(before)
        assertEquals(listOf(24L, 44L), oldOffsets)

        assertEquals(Mp4FastStart.Result.MOVED, Mp4FastStart.apply(file))

        val after = file.readBytes()
        assertEquals("aucun octet ne doit être perdu", before.size, after.size)
        assertEquals(listOf("ftyp", "moov", "mdat"), topLevelTypes(after))

        // Le vrai contrôle : ce que désignent les décalages n'a pas bougé.
        val newOffsets = chunkOffsets(after)
        for ((old, new) in oldOffsets.zip(newOffsets)) {
            assertArrayEquals(
                "le décalage $old → $new ne pointe plus sur les mêmes octets",
                before.copyOfRange(old.toInt(), old.toInt() + 8),
                after.copyOfRange(new.toInt(), new.toInt() + 8),
            )
        }
    }

    @Test
    fun `un fichier deja en tete est laisse tel quel`() {
        val file = buildMovie(moovLast = false)
        val before = file.readBytes()
        assertEquals(Mp4FastStart.Result.ALREADY_FAST, Mp4FastStart.apply(file))
        assertArrayEquals(before, file.readBytes())
    }

    @Test
    fun `deux passages ne changent rien de plus`() {
        val file = buildMovie(moovLast = true)
        assertEquals(Mp4FastStart.Result.MOVED, Mp4FastStart.apply(file))
        val once = file.readBytes()
        assertEquals(Mp4FastStart.Result.ALREADY_FAST, Mp4FastStart.apply(file))
        assertArrayEquals("l'opération doit être stable", once, file.readBytes())
    }

    @Test
    fun `un fichier non reconnu est laisse intact`() {
        val file = temp()
        val garbage = ByteArray(64) { 0x7F }
        file.writeBytes(garbage)
        val result = Mp4FastStart.apply(file)
        assertTrue(
            "un fichier incompris doit être refusé, jamais réécrit",
            result == Mp4FastStart.Result.UNSUPPORTED ||
                result == Mp4FastStart.Result.FAILED,
        )
        assertArrayEquals(garbage, file.readBytes())
    }

    // ------------------------------------------------------------------
    // Fabrication d'un MP4 minimal mais structurellement vrai
    // ------------------------------------------------------------------

    private fun buildMovie(moovLast: Boolean): File {
        val ftyp = box("ftyp", "isom".toByteArray() + int(512))
        val mdat = box("mdat", payload)
        // Les données commencent à 16 (ftyp) + 8 (en-tête mdat) = 24.
        val stco = box("stco", int(0) + int(2) + int(24) + int(44))
        val moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stco)))))

        val file = temp()
        file.writeBytes(if (moovLast) ftyp + mdat + moov else ftyp + moov + mdat)
        return file
    }

    private fun box(type: String, payload: ByteArray): ByteArray =
        int(8 + payload.size) + type.toByteArray(Charsets.US_ASCII) + payload

    private fun int(value: Int): ByteArray =
        ByteBuffer.allocate(4).putInt(value).array()

    private fun temp(): File =
        File.createTempFile("faststart", ".mp4").also { it.deleteOnExit() }

    private fun topLevelTypes(bytes: ByteArray): List<String> {
        val types = mutableListOf<String>()
        var offset = 0
        while (offset + 8 <= bytes.size) {
            val size = ByteBuffer.wrap(bytes, offset, 4).int
            types.add(String(bytes, offset + 4, 4, Charsets.US_ASCII))
            offset += size
        }
        return types
    }

    /** Relit la table `stco` telle qu'elle est réellement écrite dans le fichier. */
    private fun chunkOffsets(bytes: ByteArray): List<Long> {
        val marker = "stco".toByteArray(Charsets.US_ASCII)
        var at = -1
        outer@ for (i in 0..bytes.size - 4) {
            for (j in 0..3) if (bytes[i + j] != marker[j]) continue@outer
            at = i
            break
        }
        require(at > 0) { "table stco introuvable" }
        var cursor = at + 4 + 4 // type + version/flags
        val count = ByteBuffer.wrap(bytes, cursor, 4).int
        cursor += 4
        return (0 until count).map {
            val value = ByteBuffer.wrap(bytes, cursor, 4).int.toLong() and 0xFFFFFFFFL
            cursor += 4
            value
        }
    }
}
