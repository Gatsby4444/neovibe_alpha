package com.neovibe.neovibe

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lecture d'un média scellé **sans l'avoir téléchargé en entier**.
 *
 * Les vecteurs utilisés sont ceux du format (`docs/format-media-scelle.md`),
 * scellés par le Dart : ce test prouve donc à la fois que le streaming rend les
 * bons octets, et qu'il en rend **le moins possible**.
 *
 * L'assertion décisive n'est pas « les octets sont bons » — le lecteur local le
 * garantissait déjà. C'est **« combien d'octets ont voyagé »** : c'est la
 * seule qui distingue un vrai téléchargement progressif d'un téléchargement
 * complet déguisé, et c'est exactement le contrôle qui manquait à la v0.9.55.
 */
class PartialStreamingTest {

    private val root = File(
        javaClass.classLoader!!.getResource("seal-vectors/manifest.json")!!.toURI(),
    ).parentFile!!

    private val manifest =
        JsonParser.parseString(File(root, "manifest.json").readText()).asJsonObject

    /** Un serveur en carton : il sert des intervalles et compte ce qu'il a servi. */
    private class FakeServer(private val bytes: ByteArray) : RangeFetcher {
        var calls = 0
        var served = 0L

        override fun fetch(from: Long, toInclusive: Long): ByteArray {
            calls++
            val end = minOf(toInclusive + 1, bytes.size.toLong()).toInt()
            require(from < end) { "intervalle vide : $from-$toInclusive" }
            served += end - from
            return bytes.copyOfRange(from.toInt(), end)
        }
    }

    @Test
    fun `le clair est identique a celui d une lecture locale`() {
        for (element in manifest.getAsJsonArray("vectors")) {
            val vector = element.asJsonObject
            val name = vector.get("name").asString
            if (vector.get("length").asLong == 0L) continue // rien à lire

            val server = FakeServer(File(root, vector.get("file").asString).readBytes())
            withRemote(vector, server) { reader ->
                assertEquals(
                    "$name : le streaming ne rend pas le même clair",
                    vector.get("sha256").asString,
                    digest(reader, 0, reader.plainLength),
                )
            }
        }
    }

    @Test
    fun `la premiere image ne coute qu une requete`() {
        val vector = vector("multi_blocs")
        val server = FakeServer(File(root, vector.get("file").asString).readBytes())

        withRemote(vector, server) { reader ->
            // Ce que fait un lecteur vidéo au démarrage : il lit le tout début.
            val buffer = ByteArray(4096)
            assertTrue(reader.read(0, buffer, 0, buffer.size) > 0)
        }

        // En-tête ET premier bloc en un seul aller-retour : c'est ce qui rend
        // la cible de 300 ms atteignable, un aller-retour mobile en coûtant
        // 100 à 200 à lui seul.
        assertEquals("le démarrage doit tenir en une requête", 1, server.calls)
    }

    @Test
    fun `un saut ne coute qu un bloc, pas ce qui le precede`() {
        val vector = vector("multi_blocs")
        val total = vector.get("length").asLong
        val full = File(root, vector.get("file").asString).readBytes()
        val server = FakeServer(full)
        val buffer = ByteArray(1024)

        withRemote(vector, server) { reader ->
            reader.read(0, buffer, 0, buffer.size) // démarrage normal
            val afterStart = server.served

            // Puis un déplacement direct à la fin, comme un doigt sur la barre
            // de progression. Le coût est mesuré à part : mélanger l'amorçage
            // du démarrage et le saut donnerait un chiffre qui ne dit rien.
            assertTrue(reader.read(total - 1024, buffer, 0, buffer.size) > 0)

            val jumped = server.served - afterStart
            val oneChunk = 256L * 1024 + SealedChunkReader.OVERHEAD
            assertTrue(
                "un saut a coûté $jumped o : il devrait tenir en un bloc",
                jumped <= oneChunk,
            )
        }

        // Et rien de ce qui sépare le début de la fin n'a voyagé.
        assertTrue(
            "le fichier entier a fini par être téléchargé (${server.served} o)",
            server.served < full.size,
        )
    }

    @Test
    fun `le cache partiel evite de retelecharger`() {
        val vector = vector("multi_blocs")
        val bytes = File(root, vector.get("file").asString).readBytes()
        val data = temp("cache")
        val map = temp("carte")

        val first = FakeServer(bytes)
        SealedChunkReader(
            RemoteChunkStore(data, map, first),
            vector.get("key").asString,
        ).use { reader ->
            val buffer = ByteArray(4096)
            reader.read(0, buffer, 0, buffer.size)
        }
        assertTrue(first.calls > 0)

        // Deuxième ouverture du même média : tout ce qui a déjà servi est là.
        val second = FakeServer(bytes)
        SealedChunkReader(
            RemoteChunkStore(data, map, second),
            vector.get("key").asString,
        ).use { reader ->
            val buffer = ByteArray(4096)
            reader.read(0, buffer, 0, buffer.size)
        }
        assertEquals("une vidéo revue ne doit rien redemander", 0, second.calls)
    }

    @Test
    fun `un media entierement lu devient un fichier scelle valide`() {
        val vector = vector("multi_blocs")
        val bytes = File(root, vector.get("file").asString).readBytes()
        val data = temp("complet")
        val map = temp("complet-carte")
        val key = vector.get("key").asString

        val store = RemoteChunkStore(data, map, FakeServer(bytes))
        SealedChunkReader(store, key).use { reader ->
            digest(reader, 0, reader.plainLength)
        }
        assertTrue("tous les blocs devraient être présents", store.isComplete())

        // Le cache rempli EST le fichier scellé d'origine : c'est ce qui permet
        // au lecteur local et au lecteur distant de partager le même format —
        // et donc de ne pas avoir deux caches aux règles différentes.
        assertEquals(bytes.size.toLong(), data.length())
        SealedChunkReader(data, key).use { reader ->
            assertEquals(
                vector.get("sha256").asString,
                digest(reader, 0, reader.plainLength),
            )
        }
    }

    @Test
    fun `un bloc altere en transit est refuse`() {
        val vector = vector("petit")
        val bytes = File(root, vector.get("file").asString).readBytes().copyOf()
        bytes[SealedChunkReader.HEADER_SIZE + 20] =
            (bytes[SealedChunkReader.HEADER_SIZE + 20].toInt() xor 0x01).toByte()

        val failed = try {
            SealedChunkReader(
                RemoteChunkStore(temp("altere"), temp("altere-carte"), FakeServer(bytes)),
                vector.get("key").asString,
            ).use { it.read(0, ByteArray(64), 0, 64) }
            false
        } catch (_: Exception) {
            true
        }
        // Le réseau ne change rien à la garantie : ce qui n'est pas authentifié
        // n'est jamais rendu.
        assertTrue("un octet modifié en transit a été accepté", failed)
    }

    // ------------------------------------------------------------------

    private fun vector(name: String): JsonObject =
        manifest.getAsJsonArray("vectors")
            .map { it.asJsonObject }
            .first { it.get("name").asString == name }

    private fun withRemote(
        vector: JsonObject,
        server: FakeServer,
        block: (SealedChunkReader) -> Unit,
    ) {
        val name = vector.get("name").asString
        SealedChunkReader(
            RemoteChunkStore(temp("$name-data"), temp("$name-map"), server),
            vector.get("key").asString,
        ).use(block)
    }

    private val temps = mutableMapOf<String, File>()

    private fun temp(name: String): File = temps.getOrPut(name) {
        File.createTempFile("nvc1_$name", ".bin").also {
            it.delete() // le cache doit pouvoir se créer lui-même
            it.deleteOnExit()
        }
    }

    private fun digest(reader: SealedChunkReader, start: Long, end: Long): String {
        val sha = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8192)
        var position = start
        while (position < end) {
            val want = minOf(buffer.size.toLong(), end - position).toInt()
            val read = reader.read(position, buffer, 0, want)
            if (read <= 0) break
            sha.update(buffer, 0, read)
            position += read
        }
        return sha.digest().joinToString("") { "%02x".format(it) }
    }
}
