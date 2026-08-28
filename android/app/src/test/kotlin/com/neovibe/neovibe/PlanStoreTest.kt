package com.neovibe.neovibe

import com.neovibe.neovibe.ble.AdvertSchedule
import com.neovibe.neovibe.ble.BleConstants
import com.neovibe.neovibe.ble.PlanStore
import com.neovibe.neovibe.ble.RecognitionTable
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Ce que ces tests protegent : **la reprise apres que le systeme a tue l'app.**
 *
 * ## Pourquoi ils devaient exister
 *
 * Ce magasin s'ecrit et se relit **au seul moment ou personne ne regarde** :
 * Android a recupere le processus pendant la nuit, il le relance, et le service
 * doit repartir tout seul. S'il echoue, il n'y a ni ecran, ni erreur, ni
 * utilisateur pour le voir — le telephone cesse simplement de croiser ses amis,
 * exactement comme avant le correctif. **Une panne ici serait indiscernable de
 * la panne qu'on vient de corriger.**
 *
 * ⚠️ Le magasin a ete separe du `Context` pour rendre ces tests possibles. Sans
 * cette separation, la seule facon de les ecrire aurait ete de lancer l'app sur
 * un telephone — c'est-a-dire de ne jamais les ecrire.
 */
class PlanStoreTest {

    @get:Rule
    val dossier = TemporaryFolder()

    private val slotMillis = 900_000L
    private val tokenLength = 16
    private val creneau = 200L

    private fun cible(): File = File(dossier.root, "plan.bin")

    /** Un plan « comme en production » : l'identifiant public, puis les amis. */
    private fun planMixte(slots: Int, amis: Int): AdvertSchedule {
        val perSlot = amis + 1
        val tokens = ByteArray(slots * perSlot * tokenLength)
        val types = ByteArray(slots * perSlot)
        for (s in 0 until slots) {
            for (i in 0 until perSlot) {
                val rang = s * perSlot + i
                types[rang] = if (i == 0) BleConstants.TYPE_PUBLIC else BleConstants.TYPE_FRIEND
                for (b in 0 until tokenLength) {
                    tokens[rang * tokenLength + b] = if (b == 0) i.toByte() else (s + b).toByte()
                }
            }
        }
        return AdvertSchedule(
            fromSlot = creneau,
            slotMillis = slotMillis,
            slotCount = slots,
            perSlot = perSlot,
            tokens = tokens,
            tokenLength = tokenLength,
            types = types,
        )
    }

    private fun table(slots: Int, amis: Int): RecognitionTable {
        val tokens = ByteArray(slots * amis * tokenLength)
        for (i in 0 until slots * amis) {
            for (b in 0 until tokenLength) {
                tokens[i * tokenLength + b] = (200 - i - b).toByte()
            }
        }
        return RecognitionTable(
            tableId = 7,
            fromSlot = creneau,
            slotMillis = slotMillis,
            slotCount = slots,
            perSlot = amis,
            tokens = tokens,
            tokenLength = tokenLength,
        )
    }

    @Test
    fun `ce qu on ecrit se relit a l identique`() {
        val f = cible()
        assertTrue(PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), table(4, 2)))

        val repris = PlanStore.relire(f, creneau * slotMillis)
        assertNotNull("le plan doit se relire", repris)

        // Les jetons d'amis du creneau, dans le meme ordre qu'a l'ecriture.
        val attendu = planMixte(slots = 4, amis = 2)
            .friendsOnly()!!
            .tokensAt(creneau * slotMillis)!!
            .first
        val obtenu = repris!!.plan.tokensAt(creneau * slotMillis)!!.first
        assertEquals(2, obtenu.size)
        for (i in 0 until 2) {
            assertArrayEquals(attendu[i], obtenu[i])
        }
    }

    @Test
    fun `la table relue reconnait les memes jetons, avec le meme tableId`() {
        val f = cible()
        val originale = table(4, 2)
        PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), originale)

        val repris = PlanStore.relire(f, creneau * slotMillis)!!
        assertEquals(
            "le tableId doit survivre : sans lui, les constats du natif seraient jetes",
            7,
            repris.table.tableId,
        )

        // Le premier jeton attendu de la table doit encore etre reconnu, au meme
        // rang. Sinon un constat serait attribue a la mauvaise personne.
        val premier = ByteArray(tokenLength) { b -> (200 - 0 - b).toByte() }
        assertEquals(0, repris.table.match(premier, creneau * slotMillis))
    }

    @Test
    fun `un plan perime n est PAS repris`() {
        // ⚠️ Emettre des jetons que plus personne n'attend est indiscernable
        // d'une radio saine tout en ne se faisant reconnaitre par personne.
        val f = cible()
        PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), table(4, 2))

        assertNull(
            "quatre creneaux plus tard, le plan ne couvre plus rien",
            PlanStore.relire(f, (creneau + 4) * slotMillis),
        )
    }

    @Test
    fun `un fichier absent rend null, sans lever`() {
        assertNull(PlanStore.relire(File(dossier.root, "rien.bin"), creneau * slotMillis))
    }

    @Test
    fun `un fichier abime rend null, sans lever`() {
        // Un disque plein, un arret brutal pendant l'ecriture : le fichier
        // existe mais ne veut rien dire. On repart de zero, on ne devine pas.
        val f = cible()
        f.writeBytes(ByteArray(40) { 0x42 })
        assertNull(PlanStore.relire(f, creneau * slotMillis))
    }

    @Test
    fun `un fichier tronque rend null, sans lever`() {
        val f = cible()
        PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), table(4, 2))
        val entier = f.readBytes()
        f.writeBytes(entier.copyOfRange(0, entier.size / 2))
        assertNull(PlanStore.relire(f, creneau * slotMillis))
    }

    @Test
    fun `sans ami, on n ecrit RIEN et on efface ce qui restait`() {
        // ⚠️ Le cas du changement de compte : le fichier du precedent ne doit
        // pas survivre a un depot qui n'a plus rien a persister.
        val f = cible()
        PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), table(4, 2))
        assertTrue(f.exists())

        assertFalse(PlanStore.ecrire(f, planMixte(slots = 4, amis = 0), table(4, 0)))
        assertFalse("le fichier du compte precedent doit disparaitre", f.exists())
    }

    @Test
    fun `une table manquante n ecrit rien du tout`() {
        // Un plan sans table donnerait un appareil vu sans voir : les deux se
        // deposent ensemble ou pas du tout.
        val f = cible()
        assertFalse(PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), null))
        assertFalse(f.exists())
    }

    @Test
    fun `effacer supprime le fichier`() {
        val f = cible()
        PlanStore.ecrire(f, planMixte(slots = 4, amis = 2), table(4, 2))
        assertTrue(f.exists())
        PlanStore.effacer(f)
        assertFalse(f.exists())
    }
}
