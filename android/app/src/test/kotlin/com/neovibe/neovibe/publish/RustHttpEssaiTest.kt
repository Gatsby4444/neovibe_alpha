package com.neovibe.neovibe.publish

import com.google.gson.Gson
import com.google.gson.JsonObject
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * **Le natif contre le VRAI serveur Rust** (docs/serveur-rust.md, étape 11) :
 * [RustHttp] exactement comme s'en servent la file de publication
 * ([PublishPipeline]), la balise du ping (`LocationBeat`) et la présence en
 * soirée (`EventPresenceService`) — sans téléphone.
 *
 * Ne tourne que si un serveur d'essai est indiqué (le serveur lancé sur le
 * PC contre la base locale, `server/outils/`) :
 *
 * ```
 * NV_SERVEUR_ESSAI=http://127.0.0.1:8787 ./gradlew :app:testDebugUnitTest --tests '*RustHttpEssaiTest*'
 * ```
 *
 * Un compte neuf, effacé à la fin.
 */
class RustHttpEssaiTest {
    private val url: String? = System.getenv("NV_SERVEUR_ESSAI")
    private val http = OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build()
    private val gson = Gson()
    private val dossier = Files.createTempDirectory("essai_rust").toFile()
    private var compte: String? = null

    @Before
    fun seulementAvecUnServeur() {
        assumeTrue("NV_SERVEUR_ESSAI non défini : pas de serveur Rust à éprouver", url != null)
    }

    @After
    fun menage() {
        dossier.deleteRecursively()
        val id = compte ?: return
        // Les balises et positions suivent le profil (effacement en cascade).
        sql(
            "delete from public.profiles where id = '$id'; " +
                "delete from private.device_signups where user_id = '$id'; " +
                "delete from auth.users where id = '$id';",
        )
    }

    @Test
    fun laFileDePublicationLaBaliseEtLaPresence() {
        val session = inscrire()
        val moi = compte!!
        val distant = Serveurs.distant(session)
        assertTrue("la session dit « rust » : le natif prend le serveur Rust", distant is RustHttp)
        distant.rpc("profile_create", gson.toJson(mapOf("id" to moi, "display_name" to "essai_natif_${hasard(8)}")))

        // ─── La file de publication : trois morceaux, coupée puis reprise ────
        val taille = 2 * RustHttp.CHUNK + 1234
        val octets = Random(7).nextBytes(taille)
        val fichier = File(dossier, "scelle.bin").apply { writeBytes(octets) }
        val chemin = "$moi/essai_natif_${UUID.randomUUID()}.bin"
        val adresse = distant.tusCreate(PublishPipeline.BUCKET, chemin, fichier.length(), "application/octet-stream")
        assertEquals("rien n'est encore arrivé", 0L, distant.tusOffset(adresse))

        // Coupée après le premier morceau, comme une app tuée pendant l'envoi…
        val vus = mutableListOf<Long>()
        val coupe = distant.tusPatch(adresse, fichier, 0, onOffset = { vus.add(it) }) { vus.isNotEmpty() }
        assertEquals(RustHttp.CHUNK.toLong(), coupe)
        // … la reprise sait ce qui est arrivé, et ne renvoie rien deux fois.
        assertEquals(RustHttp.CHUNK.toLong(), distant.tusOffset(adresse))
        val fin = distant.tusPatch(adresse, fichier, coupe, onOffset = { vus.add(it) }) { false }
        assertEquals(taille.toLong(), fin)
        assertEquals(
            listOf(RustHttp.CHUNK.toLong(), 2L * RustHttp.CHUNK, taille.toLong()),
            vus,
        )
        // Assemblé, l'envoi n'existe plus comme envoi : si l'app avait été
        // tuée juste là, la file repartirait de zéro (PublishPipeline : `null`
        // → nouvel envoi), sans erreur.
        assertNull(distant.tusOffset(adresse))
        assertArrayEquals("le fichier est là, octet pour octet", octets, lire(distant, chemin))

        // Un dépôt hors de mon dossier est refusé, avec une phrase.
        try {
            distant.tusCreate(PublishPipeline.BUCKET, "${UUID.randomUUID()}/intrus.bin", 10, "application/octet-stream")
            fail("un dépôt hors de mon dossier doit être refusé")
        } catch (e: Rejected) {
            assertTrue(e.message!!, e.message!!.contains("ne t'appartient pas"))
        }

        // L'annulation efface le fichier.
        distant.deleteObject(PublishPipeline.BUCKET, chemin)
        assertFalse("le fichier effacé ne se lit plus", telechargeable(distant, chemin))

        // ─── La balise du ping (le corps exact de LocationBeat) ──────────────
        val jeton = hasard(32)
        distant.rpcText(
            "publish_ping_beacon",
            "{\"p_lat\":48.8566,\"p_lon\":2.3522,\"p_acc\":12.5,\"p_token\":\"$jeton\",\"p_slot\":123456}",
        )
        assertEquals(jeton, sql("select token from public.ping_beacons where user_id = '$moi'"))

        // ─── La présence en soirée (le corps et la lecture d'EventPresenceService) ───
        val etat = distant.rpcText("report_event_position", "{\"p_lat\":48.8566,\"p_lon\":2.3522,\"p_acc\":12.5}")
            .trim('"', ' ', '\n')
        assertEquals("dans aucune soirée", "none", etat)

        // ─── Un badge refusé : le natif s'arrête et attend l'app ─────────────
        try {
            Serveurs.distant(session.copy(accessToken = "pas-un-badge"))
                .rpcText("report_event_position", "{}")
            fail("un badge refusé doit lever AuthExpired")
        } catch (_: AuthExpired) {
        }
    }

    // ─── Outils ───────────────────────────────────────────────────────────────

    private fun hasard(n: Int) = (1..n).joinToString("") { Random.nextInt(16).toString(16) }

    /** Un compte neuf, par le guichet d'inscription ; la session que l'app déposerait. */
    private fun inscrire(): Session {
        val corps = gson.toJson(
            mapOf(
                "email" to "essai.natif.${hasard(8)}@essai.fr",
                "password" to "secret123",
                "device_hash" to hasard(64),
            ),
        )
        val req = Request.Builder().url("$url/v1/auth/inscription").post(corps.toRequestBody(JSON)).build()
        http.newCall(req).execute().use { r ->
            val texte = r.body?.string().orEmpty()
            assertEquals("inscription : $texte", 200, r.code)
            val j = gson.fromJson(texte, JsonObject::class.java)
            compte = j.getAsJsonObject("user").get("id").asString
            return Session(url!!, "", j.get("access_token").asString, serveur = "rust")
        }
    }

    private fun lienDeLecture(distant: Distant, chemin: String): String? {
        val r = distant.rpcText(
            "files_sign_read",
            gson.toJson(mapOf("bucket" to PublishPipeline.BUCKET, "paths" to listOf(chemin))),
        )
        val premier = gson.fromJson(r, com.google.gson.JsonArray::class.java)[0].asJsonObject
        return premier.get("signedUrl").takeUnless { it.isJsonNull }?.asString
    }

    private fun lire(distant: Distant, chemin: String): ByteArray {
        val lien = lienDeLecture(distant, chemin) ?: error("aucun lien de lecture pour $chemin")
        http.newCall(Request.Builder().url(lien).build()).execute().use { r ->
            assertEquals("lecture de $chemin", 200, r.code)
            return r.body!!.bytes()
        }
    }

    private fun telechargeable(distant: Distant, chemin: String): Boolean {
        val lien = lienDeLecture(distant, chemin) ?: return false
        http.newCall(Request.Builder().url(lien).build()).execute().use { r -> return r.isSuccessful }
    }

    /** Une requête sur la base du serveur (`nv_serveur`) : vérification et ménage. */
    private fun sql(requete: String): String {
        val p = ProcessBuilder(
            "docker", "exec", "-i", "nv_rust_db", "psql", "-At", "-v", "ON_ERROR_STOP=1",
            "-U", "postgres", "-d", "nv_serveur", "-c", requete,
        ).redirectErrorStream(true).start()
        val sortie = p.inputStream.bufferedReader().readText().trim()
        check(p.waitFor() == 0) { "sql : $sortie" }
        return sortie
    }

    companion object {
        private val JSON = "application/json".toMediaType()
    }
}
