package com.neovibe.neovibe

import com.google.gson.JsonParser
import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **La lecture d'avance** (2026-09-19) : servir un bloc déclenche, sur un
 * autre fil, UNE requête pour les blocs suivants — et ces blocs ne coûtent
 * ensuite plus rien. Sans elle, chaque bloc de 256 Ko était demandé quand
 * ExoPlayer le réclamait, sans anticipation : « charge et saccade ».
 */
class ReadAheadTest {
    private val root = File(
        javaClass.classLoader!!.getResource("seal-vectors/manifest.json")!!.toURI(),
    ).parentFile!!

    private val manifest =
        JsonParser.parseString(File(root, "manifest.json").readText()).asJsonObject

    private fun vector(name: String) =
        manifest.getAsJsonArray("vectors").map { it.asJsonObject }.first { it.get("name").asString == name }

    private class FakeServer(private val bytes: ByteArray) : RangeFetcher {
        var calls = 0
        val ranges = mutableListOf<LongRange>()

        override fun fetch(from: Long, toInclusive: Long): ByteArray {
            calls++
            ranges.add(from..toInclusive)
            val end = minOf(toInclusive + 1, bytes.size.toLong()).toInt()
            return bytes.copyOfRange(from.toInt(), end)
        }
    }

    /** Un exécuteur qui fait le travail sur place : le test reste déterministe. */
    private val surPlace = Executor { it.run() }

    @Test
    fun `un bloc servi amene les suivants en une requete, et ils ne coutent plus rien`() {
        val vector = vector("multi_blocs")
        val bytes = File(root, vector.get("file").asString).readBytes()
        val server = FakeServer(bytes)
        val dir = java.nio.file.Files.createTempDirectory("ahead").toFile()
        try {
            val store = RemoteChunkStore(
                File(dir, "data"),
                File(dir, "map"),
                server,
                readAhead = 4,
                prefetchExecutor = surPlace,
            )
            SealedChunkReader(store, vector.get("key").asString).use { reader ->
                val chunk = 256 * 1024
                val buffer = ByteArray(1024)
                // Le démarrage : l'amorçage (en-tête + bloc 0), puis l'avance.
                reader.read(0, buffer, 0, buffer.size)
                val apresDemarrage = server.calls
                assertEquals("amorçage + une requête d'avance", 2, apresDemarrage)
                val avance = server.ranges.last()
                assertTrue(
                    "l'avance couvre plusieurs blocs (${avance.last - avance.first + 1} o)",
                    avance.last - avance.first + 1 > chunk.toLong(),
                )

                // Le vecteur a 3 blocs : l'avance a amené les blocs 1 et 2, en
                // une seule requête, qui couvre donc tout le reste du fichier.
                assertEquals(3L, store.layout.chunkCount)
                assertEquals(store.layout.sealedOffset(1), avance.first)
                assertEquals(bytes.size.toLong() - 1, avance.last)

                // Les lire ne demande plus rien au réseau.
                reader.read(chunk.toLong() + 10, buffer, 0, buffer.size)
                reader.read(2L * chunk + 10, buffer, 0, buffer.size)
                assertEquals(
                    "les blocs d'avance ne doivent pas être redemandés — requêtes=${server.ranges}",
                    apresDemarrage,
                    server.calls,
                )
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `sans executeur, aucune avance - le comportement des autres tests`() {
        val vector = vector("multi_blocs")
        val bytes = File(root, vector.get("file").asString).readBytes()
        val server = FakeServer(bytes)
        val dir = java.nio.file.Files.createTempDirectory("ahead").toFile()
        try {
            val store = RemoteChunkStore(File(dir, "data"), File(dir, "map"), server)
            SealedChunkReader(store, vector.get("key").asString).use { reader ->
                reader.read(0, ByteArray(1024), 0, 1024)
                assertEquals(1, server.calls)
            }
        } finally {
            dir.deleteRecursively()
        }
    }
}
