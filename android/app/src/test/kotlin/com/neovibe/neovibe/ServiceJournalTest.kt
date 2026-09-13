package com.neovibe.neovibe

import com.neovibe.neovibe.ble.ServiceJournal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Ce que ces tests protegent : **le carnet qui doit survivre a la nuit.**
 *
 * Il s'ecrit au seul moment ou personne ne regarde, et il est relu apres que
 * ce qui l'ecrivait est mort. S'il perd sa derniere ligne, se coupe au milieu
 * d'une ligne ou leve une exception dans le service qu'il decrit, le prochain
 * test de nuit sera aussi muet que celui du 2026-09-13.
 */
class ServiceJournalTest {

    @get:Rule
    val dossier = TemporaryFolder()

    private fun cible(): File = File(dossier.root, "service.log")

    @Test
    fun `chaque ligne porte les deux horloges, l'evenement et le detail`() {
        val f = cible()
        ServiceJournal.note(f, "cree", null, 1_000L, 51_234_567L)
        ServiceJournal.note(f, "alarme", "retard=312ms", 2_000L, 51_235_000L)

        val lignes = ServiceJournal.lire(f).trimEnd().lines()
        assertEquals(2, lignes.size)
        // L'heure murale depend du fuseau de la machine de test : on verifie
        // la forme, pas la valeur.
        assertTrue(lignes[0], Regex("""^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} up=51234s cree$""").matches(lignes[0]))
        assertTrue(lignes[1], lignes[1].endsWith(" up=51235s alarme — retard=312ms"))
    }

    @Test
    fun `un carnet absent se lit vide, sans lever`() {
        assertEquals("", ServiceJournal.lire(cible()))
    }

    @Test
    fun `passe la borne, on garde la fin sur une frontiere de ligne`() {
        val f = cible()
        // ~60 octets par ligne : 600 lignes depassent largement 24 Ko.
        for (i in 0 until 600) {
            ServiceJournal.note(f, "alarme", "retard=${i}ms", i * 1_000L, i * 1_000L)
        }
        val texte = ServiceJournal.lire(f)
        assertTrue("taille ${texte.length}", texte.length <= ServiceJournal.TAILLE_MAX)
        val lignes = texte.trimEnd().lines()
        assertEquals(ServiceJournal.MARQUE_COUPE, lignes.first())
        // La premiere ligne gardee est entiere : elle commence par une date.
        assertTrue(lignes[1], Regex("""^\d{4}-""").containsMatchIn(lignes[1]))
        // Et la derniere ecrite est toujours la : la coupe ne mange que l'ancien.
        assertTrue(lignes.last(), lignes.last().endsWith("retard=599ms"))
    }
}
