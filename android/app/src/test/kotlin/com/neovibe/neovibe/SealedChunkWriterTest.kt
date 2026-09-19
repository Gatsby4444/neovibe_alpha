package com.neovibe.neovibe

import java.io.File
import java.security.SecureRandom
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Le scelleur natif produit ce que le lecteur natif lit — et le format que le
 * Dart lit (mêmes en-tête, mêmes blocs : `docs/format-media-scelle.md`).
 */
class SealedChunkWriterTest {
    private fun key(): String {
        val k = ByteArray(32)
        SecureRandom().nextBytes(k)
        return Base64.getEncoder().encodeToString(k)
    }

    private fun roundTrip(size: Int) {
        val dir = java.nio.file.Files.createTempDirectory("seal").toFile()
        try {
            val clear = ByteArray(size).also { SecureRandom().nextBytes(it) }
            val source = File(dir, "clear.bin").apply { writeBytes(clear) }
            val sealed = File(dir, "sealed.nvc1")
            val k = key()
            SealedChunkWriter.seal(source, sealed, k)
            assertTrue("le .part ne doit pas rester", !File(sealed.path + ".part").exists())

            // L'en-tête, tel que le Dart le lit.
            val head = sealed.inputStream().use { it.readNBytes(16) }
            val magic = java.nio.ByteBuffer.wrap(head).int
            val chunk = java.nio.ByteBuffer.wrap(head, 4, 4).int
            val length = java.nio.ByteBuffer.wrap(head, 8, 8).long
            assertEquals(0x4E564331, magic)
            assertEquals(SealedChunkWriter.CHUNK_SIZE, chunk)
            assertEquals(size.toLong(), length)
            // La taille scellée est calculable : en-tête + 28 octets par bloc.
            val blocs = (size + chunk - 1) / chunk
            assertEquals(16L + size + 28L * blocs, sealed.length())

            // Le lecteur natif relit exactement le clair.
            SealedChunkReader(sealed, k).use { reader ->
                assertEquals(size.toLong(), reader.plainLength)
                val out = ByteArray(size)
                var pos = 0L
                while (pos < size) {
                    val n = reader.read(pos, out, pos.toInt(), size - pos.toInt())
                    assertTrue(n > 0)
                    pos += n
                }
                assertArrayEquals(clear, out)
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun `un fichier vide`() = roundTrip(0)
    @Test fun `un bloc partiel`() = roundTrip(1000)
    @Test fun `un bloc exact`() = roundTrip(256 * 1024)
    @Test fun `plusieurs blocs, le dernier partiel`() = roundTrip(3 * 256 * 1024 + 777)
}
