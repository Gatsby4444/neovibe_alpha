package com.neovibe.neovibe

import com.neovibe.neovibe.map.TwoFingerArbiter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * L'arbitrage à deux doigts de la carte (2026-09-26). Deux doigts côte à
 * côte, à 600 px l'un de l'autre, comme dans le journal de Jay.
 */
class TwoFingerArbiterTest {

    private fun choix(
        dax: Float, day: Float, dbx: Float, dby: Float,
        ax: Float = 240f, ay: Float = 1200f, bx: Float = 840f, by: Float = 1200f,
        regle: Boolean = true,
    ) = TwoFingerArbiter.parts(
        ax, ay, bx, by, ax + dax, ay + day, bx + dbx, by + dby,
        deuxDoigtsPourIncliner = regle,
    ).choix

    @Test
    fun `deux doigts qui montent ensemble inclinent`() {
        assertEquals(TwoFingerArbiter.GLISSEMENT, choix(0f, -40f, 0f, -40f))
    }

    @Test
    fun `un doigt fixe et l'autre qui monte, ce n'est PAS une inclinaison`() {
        // La règle de Jay : un fixe et un qui bouge, c'est tourner.
        assertEquals(TwoFingerArbiter.ROTATION, choix(0f, -60f, 0f, -4f))
    }

    @Test
    fun `sans la règle, le même geste incline`() {
        assertEquals(TwoFingerArbiter.GLISSEMENT, choix(0f, -60f, 0f, -4f, regle = false))
    }

    @Test
    fun `deux doigts dans des directions trop différentes n'inclinent pas`() {
        // L'un monte, l'autre part de côté : plus de 60° entre eux. Ce
        // n'est pas une inclinaison (ce qu'il devient — zoom ou rotation —
        // dépend de la ligne des doigts, et n'est pas l'objet de la règle).
        assertNotEquals(TwoFingerArbiter.GLISSEMENT, choix(0f, -40f, 40f, -5f))
        assertEquals(TwoFingerArbiter.GLISSEMENT, choix(0f, -40f, 40f, -5f, regle = false))
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

    @Test
    fun `sens opposés verticaux, doigts qui penchent de 30°, tournent`() {
        // 🔴 Le second défaut (journal de 14:58) : la ligne des doigts
        // penche, le glissement vertical opposé change aussi l'écart, et le
        // zoom — compté double — gagnait.
        assertEquals(
            TwoFingerArbiter.ROTATION,
            choix(0f, 30f, 0f, -30f, ax = 280f, ay = 1300f, bx = 800f, by = 1000f),
        )
    }

    @Test
    fun `sens opposés verticaux, doigts qui penchent de 45°, tournent encore`() {
        // À 45°, le mouvement change autant l'écart que l'angle : égalité,
        // et la rotation passe devant (elle laisse encore zoomer).
        assertEquals(
            TwoFingerArbiter.ROTATION,
            choix(0f, 30f, 0f, -30f, ax = 240f, ay = 1500f, bx = 664f, by = 1076f),
        )
    }
}
