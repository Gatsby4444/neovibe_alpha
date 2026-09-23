package com.neovibe.neovibe

import android.bluetooth.le.ScanCallback
import com.neovibe.neovibe.ble.ScanRecovery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * La reprise de l'ecoute apres un refus d'Android (2026-09-23) : le telephone
 * de Jay est reste sourd plus d'une heure faute de ce chemin.
 */
class ScanRecoveryTest {

    @Test
    fun `le refus du 2026-09-23 se reessaie seul`() {
        assertTrue(
            ScanRecovery.reprendSeul(ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED),
        )
        assertTrue(ScanRecovery.reprendSeul(ScanCallback.SCAN_FAILED_INTERNAL_ERROR))
        assertTrue(ScanRecovery.reprendSeul(ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES))
    }

    @Test
    fun `ce qui a deja son chemin, ou ne se repare pas, n'est pas repris ici`() {
        assertFalse(ScanRecovery.reprendSeul(ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED))
        assertFalse(ScanRecovery.reprendSeul(ScanCallback.SCAN_FAILED_ALREADY_STARTED))
        assertFalse(ScanRecovery.reprendSeul(ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY))
    }

    @Test
    fun `de plus en plus espace, jamais abandonne`() {
        assertEquals(5_000L, ScanRecovery.delaiApres(1))
        assertEquals(30_000L, ScanRecovery.delaiApres(2))
        assertEquals(120_000L, ScanRecovery.delaiApres(3))
        assertEquals(300_000L, ScanRecovery.delaiApres(4))
        assertEquals(300_000L, ScanRecovery.delaiApres(50))
    }

    @Test
    fun `les deux premiers essais tiennent dans le quota d'Android`() {
        // Quelques startScan par tranche de 30 s : les deux premiers essais
        // doivent laisser de la marge, sinon on se fait bannir.
        val deuxPremiers = ScanRecovery.delaiApres(1) + ScanRecovery.delaiApres(2)
        assertTrue(ScanRecovery.delaiApres(1) >= 5_000L)
        assertTrue(deuxPremiers >= 30_000L)
    }
}
