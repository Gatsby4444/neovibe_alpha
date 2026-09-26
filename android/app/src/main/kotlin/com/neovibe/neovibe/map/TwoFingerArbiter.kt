package com.neovibe.neovibe.map

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/**
 * **Quel geste font deux doigts ?** — l'arbitrage à deux doigts, en calcul
 * pur (testé : `TwoFingerArbiterTest`).
 *
 * ## 🔴 Corrigé le 2026-09-26 — l'inclinaison prise pour une rotation
 *
 * La première version ne comptait le glissement que si les deux doigts
 * allaient EXACTEMENT dans le même sens (produit scalaire positif) : un
 * doigt qui reculait d'un pixel au départ, et le glissement valait ZÉRO —
 * la rotation gagnait. Journal de Jay (14:44) : « glissé 0 px » sur des
 * gestes voulus comme des inclinaisons, et des inclinaisons gagnées de
 * justesse (glissé 66 contre arc 53).
 *
 * ## Le calcul : ce que les doigts font ENSEMBLE, et l'un PAR RAPPORT à l'autre
 *
 * Deux déplacements de doigts `da` et `db` se décomposent sans reste :
 *
 * - **ensemble** : `(da + db) / 2` — le glissement commun (déplacement,
 *   puis inclinaison s'il est vertical) ;
 * - **l'un par rapport à l'autre** : `(db − da) / 2`, lui-même coupé en
 *   deux, le long de la ligne des doigts (ils s'écartent : **zoom**) et en
 *   travers (ils tournent : **rotation**).
 *
 * Plus de tout-ou-rien : chaque part se mesure, en pixels, pour chaque
 * geste. Le zoom compte la variation d'écart ENTIÈRE (deux fois la part
 * le long de la ligne), comme avant : pincer reste le geste le plus facile
 * à déclencher (les pincements marchaient ; on n'y touche pas).
 *
 * La rotation, elle, ne compte que pour [ROTATION_POIDS] : un doigt qui
 * monte pendant que l'autre bouge à peine fait autant de « rotation » que
 * de « glissement » — c'est le geste d'inclinaison mal fait, et Jay veut
 * alors une inclinaison. Une rotation doit être NETTE pour gagner : deux
 * doigts qui tournent vraiment en sens opposés ne glissent pas du tout.
 */
object TwoFingerArbiter {

    /** Poids de la rotation face au glissement (voir la doc de l'objet). */
    const val ROTATION_POIDS = 0.7f

    const val GLISSEMENT = "glissement"
    const val ROTATION = "rotation"
    const val ZOOM = "zoom"

    /** Les trois parts d'un mouvement de deux doigts, en pixels. */
    data class Parts(val zoom: Float, val rotation: Float, val glissement: Float) {
        val plusGrande get() = max(zoom, max(rotation, glissement))

        /** Le geste qui domine ; à égalité, le glissement puis la rotation. */
        val choix
            get() = when (plusGrande) {
                glissement -> GLISSEMENT
                rotation -> ROTATION
                else -> ZOOM
            }
    }

    /**
     * Les doigts étaient en (ax0, ay0) et (bx0, by0) ; ils sont en
     * (ax, ay) et (bx, by).
     */
    fun parts(
        ax0: Float, ay0: Float, bx0: Float, by0: Float,
        ax: Float, ay: Float, bx: Float, by: Float,
    ): Parts {
        val dax = ax - ax0
        val day = ay - ay0
        val dbx = bx - bx0
        val dby = by - by0
        // Ensemble.
        val glissement = hypot((dax + dbx) / 2, (day + dby) / 2)
        // L'un par rapport à l'autre, dans le repère de la ligne des doigts.
        val lx = bx0 - ax0
        val ly = by0 - ay0
        val l = hypot(lx, ly)
        if (l == 0f) return Parts(0f, 0f, glissement)
        val ux = lx / l
        val uy = ly / l
        val rx = (dbx - dax) / 2
        val ry = (dby - day) / 2
        val leLong = rx * ux + ry * uy // s'écartent (+) ou se rapprochent (−)
        val enTravers = -rx * uy + ry * ux // tournent
        return Parts(
            zoom = abs(leLong) * 2,
            rotation = abs(enTravers) * ROTATION_POIDS,
            glissement = glissement,
        )
    }
}
