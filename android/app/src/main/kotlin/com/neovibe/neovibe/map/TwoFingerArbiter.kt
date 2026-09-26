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
 * Plus de tout-ou-rien : chaque part se mesure, **dans la même unité** —
 * ce que parcourt CHAQUE doigt.
 *
 * ## 🔴 Corrigé une seconde fois, le même jour — la rotation prise pour un zoom
 *
 * La version du matin comptait le zoom en variation d'écart ENTIÈRE (deux
 * fois ce que parcourt chaque doigt) et la rotation à 70 % : un zoom valait
 * près de trois fois une rotation. Or le geste de rotation de Jay — deux
 * doigts qui glissent à la verticale en sens opposés — sur des doigts dont
 * la ligne penche (20 à 45° dans son journal) change aussi l'écart. Le zoom
 * gagnait presque toujours (journal de 14:58 : 12 zooms, 1 rotation, sur
 * des gestes voulus comme des rotations). Coefficients retirés : trois
 * parts dans la même unité, et à égalité — à [TOLERANCE] près — la
 * rotation passe devant le zoom, parce qu'une rotation laisse encore
 * zoomer (règle 3 de Google) alors qu'un zoom interdit ensuite de tourner
 * (règle 1).
 *
 * *Essayée puis écartée par Jay le 2026-09-26 (v0.9.290)* : une « règle des
 * deux doigts » (pas d'inclinaison si un doigt reste fixe). Retirée du code
 * à sa demande ; retrouvable dans l'historique Git.
 */
object TwoFingerArbiter {

    /** À 5 % près, la rotation l'emporte sur le zoom (voir la doc). */
    const val TOLERANCE = 0.95f

    const val GLISSEMENT = "glissement"
    const val ROTATION = "rotation"
    const val ZOOM = "zoom"

    /** Les trois parts d'un mouvement de deux doigts, en pixels. */
    data class Parts(val zoom: Float, val rotation: Float, val glissement: Float) {
        val plusGrande get() = max(zoom, max(rotation, glissement))

        /**
         * Le geste qui domine. À égalité exacte, le glissement d'abord ; et
         * la rotation l'emporte sur le zoom à [TOLERANCE] près.
         */
        val choix
            get() = when {
                glissement >= rotation && glissement >= zoom -> GLISSEMENT
                rotation >= zoom * TOLERANCE -> ROTATION
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
            zoom = abs(leLong),
            rotation = abs(enTravers),
            glissement = glissement,
        )
    }
}
