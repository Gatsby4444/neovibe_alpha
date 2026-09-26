package com.neovibe.neovibe

import com.neovibe.neovibe.map.TwoFingerArbiter
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * L'arbitrage à deux doigts de la carte (2026-09-26). Deux doigts côte à
 * côte, à 600 px l'un de l'autre, comme dans le journal de Jay.
 */
class TwoFingerArbiterTest {

    private fun choix(
        dax: Float, day: Float, dbx: Float, dby: Float,
        ax: Float = 240f, ay: Float = 1200f, bx: Float = 840f, by: Float = 1200f,
    ) = TwoFingerArbiter.parts(ax, ay, bx, by, ax + dax, ay + day, bx + dbx, by + dby).choix

    @Test
    fun `deux doigts qui montent ensemble inclinent`() {
        assertEquals(TwoFingerArbiter.GLISSEMENT, choix(0f, -40f, 0f, -40f))
    }

    @Test
    fun `un doigt qui recule d'un pixel ne fait plus une rotation`() {
        // 🔴 Le cas du journal : l'un monte franchement, l'autre recule à
        // peine au départ. L'ancien calcul donnait « glissé 0 » → rotation.
        assertEquals(TwoFingerArbiter.GLISSEMENT, choix(0f, -60f, 0f, 1f))
    }

    @Test
    fun `l'un monte plus que l'autre reste une inclinaison`() {
        assertEquals(TwoFingerArbiter.GLISSEMENT, choix(3f, -50f, -2f, -15f))
    }

    @Test
    fun `sens opposés verticaux tournent`() {
        assertEquals(TwoFingerArbiter.ROTATION, choix(0f, -30f, 0f, 30f))
    }

    @Test
    fun `s'écarter zoome`() {
        assertEquals(TwoFingerArbiter.ZOOM, choix(-25f, 0f, 25f, 0f))
    }

    @Test
    fun `un pincement un peu tournant reste un zoom`() {
        // Écart +40, et 10 px de travers : le zoom compte l'écart entier.
        assertEquals(TwoFingerArbiter.ZOOM, choix(-20f, -5f, 20f, 5f))
    }

    @Test
    fun `doigts l'un au-dessus de l'autre qui s'écartent zooment`() {
        assertEquals(
            TwoFingerArbiter.ZOOM,
            choix(0f, -20f, 0f, 20f, ax = 540f, ay = 900f, bx = 540f, by = 1500f),
        )
    }
}
