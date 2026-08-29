package com.neovibe.neovibe

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.neovibe.neovibe.ble.AdvertSchedule
import com.neovibe.neovibe.ble.BleConstants
import com.neovibe.neovibe.ble.RecognitionTable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * **Le cote KOTLIN du point de contact avec le Dart.**
 *
 * ## 🔴 Le trou que ce test bouche — releve le 2026-08-29
 *
 * Le plan d'emission et la table de reconnaissance sont **ecrits en Dart et lus
 * ici**. `AdvertScheduleTest` et `SightingBookTest` eprouvent ce fichier-ci avec
 * **leurs propres fixtures** ; `advert_plan_test.dart` eprouve l'autre cote avec
 * les siennes. Rien ne verifiait qu'ils rangent les octets de la meme facon.
 *
 * ⚠️ **Une transposition serait parfaitement silencieuse.** Si on lisait la
 * table « ami par ami » la ou le Dart l'ecrit « creneau par creneau », tout
 * compilerait, les tests des deux cotes resteraient verts, et le seul symptome
 * serait : *l'appareil est entendu dix fois par seconde et reconnu zero fois*.
 *
 * ⚠️ **Ces vecteurs ne se regenerent pas pour faire passer un test.** Un echec
 * ici veut dire « le format a change cote Dart » — et la question suivante est
 * « ce fichier a-t-il change avec ? ». Regenerer sans y repondre laisse les deux
 * implementations fausses **ensemble**, ce qui est pire qu'une seule fausse :
 * plus rien ne les departage.
 *
 * Production des vecteurs :
 * `NEOVIBE_REGEN=1 flutter test test/recognition_vectors_test.dart`
 */
class RecognitionVectorsTest {

    private val manifeste: JsonObject by lazy {
        // ⚠️ Chemin depuis `android/app` — la racine d'execution des tests JVM.
        val f = File("src/test/resources/recognition-vectors/manifest.json")
        check(f.exists()) {
            "Vecteurs absents (" + f.absolutePath + "). Les generer avec : " +
                "NEOVIBE_REGEN=1 flutter test test/recognition_vectors_test.dart"
        }
        JsonParser.parseString(f.readText()).asJsonObject
    }

    private val slotMillis: Long get() = manifeste["slotMillis"].asLong
    private val tokenLength: Int get() = manifeste["tokenLength"].asInt

    private fun octets(base64: String): ByteArray = Base64.getDecoder().decode(base64)

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    private fun deHex(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private fun table(): RecognitionTable {
        val t = manifeste["table"].asJsonObject
        return RecognitionTable(
            tableId = t["tableId"].asInt,
            fromSlot = t["fromSlot"].asLong,
            slotMillis = slotMillis,
            slotCount = t["slotCount"].asInt,
            perSlot = t["perSlot"].asInt,
            tokens = octets(t["tokens"].asString),
            tokenLength = tokenLength,
        )
    }

    private fun plan(): AdvertSchedule {
        val p = manifeste["plan"].asJsonObject
        return AdvertSchedule(
            fromSlot = p["fromSlot"].asLong,
            slotMillis = slotMillis,
            slotCount = p["slotCount"].asInt,
            perSlot = p["perSlot"].asInt,
            tokens = octets(p["tokens"].asString),
            tokenLength = tokenLength,
            types = octets(p["types"].asString),
        )
    }

    // ------------------------------------------------------------------
    // La reconnaissance
    // ------------------------------------------------------------------

    @Test
    fun `chaque sonde du Dart trouve ce que le Dart annonce`() {
        val table = table()
        val sondes = manifeste["sondes"].asJsonArray
        check(sondes.size() >= 5) { "vecteurs trop pauvres pour prouver quoi que ce soit" }

        for (element in sondes) {
            val sonde = element.asJsonObject
            val pourquoi = sonde["pourquoi"].asString
            // Milieu du creneau : on eprouve la regle, pas un effet de bord.
            val instant = sonde["auCreneau"].asLong * slotMillis + slotMillis / 2
            val rang = table.match(deHex(sonde["jeton"].asString), instant)

            if (sonde["rangAttendu"].isJsonNull) {
                assertNull(pourquoi, rang)
            } else {
                assertEquals(pourquoi, sonde["rangAttendu"].asInt, rang)
            }
        }
    }

    @Test
    fun `la taille de jeton est celle que l'annonce transporte`() {
        // ⚠️ Une divergence ici rendrait TOUTE reconnaissance impossible, sur
        // tous les appareils, sans lever la moindre erreur. `ADVERT_PAYLOAD_SIZE`
        // = 2 octets de magie + 1 de version + 1 de type + le jeton.
        assertEquals(
            "le jeton du Dart ne tient pas dans l'annonce du natif",
            BleConstants.ADVERT_PAYLOAD_SIZE - 4,
            tokenLength,
        )
    }

    // ------------------------------------------------------------------
    // Le plan d'emission
    // ------------------------------------------------------------------

    @Test
    fun `le plan rend les jetons du Dart, dans l'ordre du Dart`() {
        val plan = plan()
        for (element in manifeste["sondesPlan"].asJsonArray) {
            val sonde = element.asJsonObject
            val creneau = sonde["auCreneau"].asLong
            val instant = creneau * slotMillis + slotMillis / 2

            val duCreneau = plan.tokensAt(instant, avecPublic = true)
            checkNotNull(duCreneau) { "le plan ne couvre pas le creneau " + creneau }

            val attendus = sonde["jetons"].asJsonArray.map { it.asString }
            assertEquals(
                "les jetons du creneau " + creneau,
                attendus,
                duCreneau.first.map { hex(it) },
            )

            val typesAttendus = sonde["types"].asJsonArray.map { it.asInt.toByte() }
            assertEquals(
                "les TYPES du creneau " + creneau + " — un jeton d'ami pris pour " +
                    "un identifiant public rend l'appareil inconnaissable",
                typesAttendus,
                duCreneau.second.toList(),
            )
        }
    }

    @Test
    fun `sans le droit de crier l'identifiant public, il ne reste que les amis`() {
        // ⚠️ L'homme mort de l'identifiant public (2026-08-28) : le Dart mort,
        // le jeton public ne vaut plus rien et doit cesser de partir — les
        // jetons d'AMIS, eux, continuent douze heures.
        val plan = plan()
        for (element in manifeste["sondesPlan"].asJsonArray) {
            val sonde = element.asJsonObject
            val instant = sonde["auCreneau"].asLong * slotMillis + slotMillis / 2
            val duCreneau = plan.tokensAt(instant, avecPublic = false)
            checkNotNull(duCreneau)

            assertEquals(
                "seuls les jetons d'amis restent",
                sonde["sansPublic"].asJsonArray.map { it.asString },
                duCreneau.first.map { hex(it) },
            )
            assertEquals(
                "aucun jeton public ne doit subsister",
                emptyList<Byte>(),
                duCreneau.second.toList().filter { it == BleConstants.TYPE_PUBLIC },
            )
        }
    }
}
