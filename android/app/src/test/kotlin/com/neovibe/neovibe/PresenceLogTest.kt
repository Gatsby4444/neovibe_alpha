package com.neovibe.neovibe

import com.neovibe.neovibe.ble.PresenceLog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ce que ces tests defendent : **la duree d'un contact, mesuree pendant que
 * personne ne regarde.**
 *
 * C'est la moitie du systeme des waves qui tourne quand l'interface a disparu.
 * Une erreur ici ne leve rien, ne s'affiche nulle part, et ne se voit qu'en
 * recevant une notification de trop — ou aucune.
 */
class PresenceLogTest {

    private val gap = 30_000L
    private val t = 1_700_000_000_000L

    private fun journal() = PresenceLog().apply { gapMillis = gap }

    @Test
    fun `une suite d'annonces fait UNE presence, avec sa duree`() {
        val log = journal()
        for (i in 0..10) log.note(1, 0, t + i * 1_000L)

        val out = log.drain(t + 60_000L)
        assertEquals(1, out.size)
        assertEquals(t, out[0].debutMillis)
        assertEquals(t + 10_000L, out[0].finMillis)
        assertEquals(11, out[0].detections)
    }

    @Test
    fun `un silence plus long que le seuil coupe en DEUX presences`() {
        val log = journal()
        log.note(1, 0, t)
        log.note(1, 0, t + 5_000L)
        // Plus de 30 s sans rien : la premiere presence est finie.
        log.note(1, 0, t + 5_000L + gap + 1)
        log.note(1, 0, t + 5_000L + gap + 2_000L)

        val out = log.drain(t + 300_000L)
        assertEquals(2, out.size)
        assertEquals(5_000L, out[0].finMillis - out[0].debutMillis)
        assertEquals(1_999L, out[1].finMillis - out[1].debutMillis)
    }

    @Test
    fun `un silence PLUS COURT que le seuil ne coupe pas`() {
        // C'est le trou de radio ordinaire : il ne doit pas fabriquer deux
        // contacts brefs la ou il y a eu une vraie presence continue.
        val log = journal()
        log.note(1, 0, t)
        log.note(1, 0, t + gap - 1_000L)

        val out = log.drain(t + 300_000L)
        assertEquals(1, out.size)
        assertEquals(gap - 1_000L, out[0].finMillis - out[0].debutMillis)
    }

    @Test
    fun `une presence encore vivante n'est PAS rendue`() {
        val log = journal()
        log.note(1, 0, t)
        // On draine juste apres : le contact n'est pas fini, il ne se juge pas.
        assertTrue(log.drain(t + 1_000L).isEmpty())
        assertEquals(1, log.enCoursCount)
    }

    @Test
    fun `drain ferme ce qui n'a plus rien donne`() {
        // 🔴 Le contre-test du parametre `nowMillis`. Sans lui, une presence qui
        // s'acheve pendant que le Dart est absent resterait ouverte pour
        // toujours et ne serait JAMAIS jugee.
        val log = journal()
        log.note(1, 0, t)
        assertTrue(log.drain(t + 1_000L).isEmpty())

        val out = log.drain(t + gap + 1_000L)
        assertEquals(1, out.size)
        assertEquals(0, log.enCoursCount)
    }

    @Test
    fun `un changement de table coupe la presence, meme sans silence`() {
        // Le rang n'a de sens que pour la table qui l'a produit : prolonger
        // au-dela attribuerait la fin d'une presence a quelqu'un d'autre.
        val log = journal()
        log.note(1, 0, t)
        log.note(2, 0, t + 1_000L)

        val out = log.drain(t + 300_000L)
        assertEquals(2, out.size)
        assertEquals(1, out[0].tableId)
        assertEquals(2, out[1].tableId)
    }

    @Test
    fun `deux amis sont suivis separement`() {
        val log = journal()
        log.note(1, 0, t)
        log.note(1, 1, t + 500L)
        log.note(1, 0, t + 2_000L)

        val out = log.drain(t + 300_000L).sortedBy { it.friendIndex }
        assertEquals(2, out.size)
        assertEquals(2_000L, out[0].finMillis - out[0].debutMillis)
        assertEquals(0L, out[1].finMillis - out[1].debutMillis)
    }

    @Test
    fun `une annonce en retard ne fait jamais reculer la fin`() {
        // Les rappels de scan n'arrivent pas toujours dans l'ordre.
        val log = journal()
        log.note(1, 0, t)
        log.note(1, 0, t + 5_000L)
        log.note(1, 0, t + 2_000L)

        val out = log.drain(t + 300_000L)
        assertEquals(5_000L, out[0].finMillis - out[0].debutMillis)
        assertEquals(3, out[0].detections)
    }

    @Test
    fun `plein, on jette le PLUS ANCIEN`() {
        // ⚠️ Refuser les nouvelles entrees perdrait justement les contacts que
        // la regle doit juger : elle ne regarde que les trois dernieres heures.
        val log = PresenceLog(maxEntries = 3).apply { gapMillis = gap }
        for (i in 0 until 5) {
            log.note(1, i, t + i * 1_000L)
            log.drain(t + i * 1_000L + gap + 1)
        }
        // Les trois derniers rangs, pas les trois premiers.
        val restants = log.drain(t + 1_000_000L)
        assertTrue(restants.isEmpty())
    }
}
