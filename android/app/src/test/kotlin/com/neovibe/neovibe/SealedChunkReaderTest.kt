package com.neovibe.neovibe

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Vecteurs de test **croisés** du format `NVC1`.
 *
 * Les mêmes fichiers sont rejoués côté Dart par
 * `test/sealed_format_vectors_test.dart`. Ils ont été **scellés par
 * l'implémentation Dart** : ce test vérifie donc que le Kotlin retrouve
 * exactement le clair d'origine, octet pour octet, y compris sur les
 * intervalles à cheval sur une frontière de bloc.
 *
 * C'est le seul dispositif qui empêche les deux implémentations de diverger.
 * Une divergence ne se verrait ni à la compilation, ni au diff — seulement à
 * l'exécution, sur l'appareil de Jay.
 *
 * Voir `docs/format-media-scelle.md` §6. **Ne jamais régénérer les vecteurs
 * pour faire passer ce test** : les deux implémentations seraient alors fausses
 * ensemble, et le dispositif ne servirait plus à rien.
 */
class SealedChunkReaderTest {

    private val root = resource("seal-vectors/manifest.json").parentFile!!
    private val manifest =
        JsonParser.parseString(File(root, "manifest.json").readText()).asJsonObject

    @Test
    fun `chaque vecteur rend le clair attendu`() {
        val vectors = manifest.getAsJsonArray("vectors")
        assertTrue("aucun vecteur trouvé", vectors.size() > 0)

        for (element in vectors) {
            val vector = element.asJsonObject
            val name = vector.get("name").asString
            val file = File(root, vector.get("file").asString)
            val key = vector.get("key").asString
            val length = vector.get("length").asLong

            assertTrue("$name : magie NVC1 non reconnue", SealedChunkReader.isSealed(file))

            SealedChunkReader(file, key).use { reader ->
                assertEquals("$name : longueur du clair", length, reader.plainLength)
                assertEquals(
                    "$name : clair entier",
                    vector.get("sha256").asString,
                    digest(reader, 0, length),
                )
                for (range in vector.getAsJsonArray("ranges")) {
                    val bounds = range.asJsonObject
                    val start = bounds.get("start").asLong
                    val end = bounds.get("end").asLong
                    assertEquals(
                        "$name : intervalle [$start, $end)",
                        bounds.get("sha256").asString,
                        digest(reader, start, end),
                    )
                }
            }
        }
    }

    @Test
    fun `un octet modifie fait echouer l authentification`() {
        val vector = firstVectorNamed("petit")
        val altered = File.createTempFile("nvc1_altere", ".bin")
        altered.deleteOnExit()
        val bytes = File(root, vector.get("file").asString).readBytes()
        // Un octet du chiffré, hors en-tête et hors nonce.
        bytes[SealedChunkReader.HEADER_SIZE + 20] =
            (bytes[SealedChunkReader.HEADER_SIZE + 20].toInt() xor 0x01).toByte()
        altered.writeBytes(bytes)

        SealedChunkReader(altered, vector.get("key").asString).use { reader ->
            val failed = try {
                reader.read(0, ByteArray(64), 0, 64)
                false
            } catch (_: Exception) {
                true
            }
            // C'est TOUT l'intérêt de GCM par rapport à CTR : un octet modifié
            // se détecte. Si ce test tombe, l'authentification a été perdue en
            // route et le format ne vaut plus sa promesse.
            assertTrue("un octet modifié a été rendu sans erreur", failed)
        }
    }

    @Test
    fun `un fichier tronque est refuse a l ouverture`() {
        val vector = firstVectorNamed("multi_blocs")
        val truncated = File.createTempFile("nvc1_tronque", ".bin")
        truncated.deleteOnExit()
        val bytes = File(root, vector.get("file").asString).readBytes()
        truncated.writeBytes(bytes.copyOf(bytes.size - 100))

        val failed = try {
            SealedChunkReader(truncated, vector.get("key").asString).close()
            false
        } catch (_: Exception) {
            true
        }
        assertTrue("un média tronqué s'est ouvert sans rien signaler", failed)
    }

    private fun firstVectorNamed(name: String): JsonObject =
        manifest.getAsJsonArray("vectors")
            .map { it.asJsonObject }
            .first { it.get("name").asString == name }

    /** Lit `[start, end)` par petits paquets — comme le fera le lecteur vidéo. */
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
        assertEquals("longueur lue", end - start, position - start)
        return sha.digest().joinToString("") { "%02x".format(it) }
    }

    private fun resource(path: String): File =
        File(javaClass.classLoader!!.getResource(path)!!.toURI())
}
