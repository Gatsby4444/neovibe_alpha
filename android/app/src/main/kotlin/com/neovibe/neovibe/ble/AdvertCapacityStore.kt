package com.neovibe.neovibe.ble

import android.content.Context
import android.os.Build

/**
 * **Ce que CETTE puce a accepté, retenu d'une session à l'autre.**
 *
 * ## Pourquoi ce magasin existe — 2026-09-01
 *
 * Consigne de Jay : *« tous les telephones sont differents, on ne code pas que
 * sur mon telephone […] il faudrait un systeme automatique qui detecte la
 * capacite de la puce et ajuste le plafond automatiquement par telephone. »*
 *
 * Le plafond de jeux d'annonces simultanes etait une **constante ecrite dans le
 * code** (6, « raisonnee, pas mesuree »). Une constante ne peut etre juste que
 * pour un seul modele : trop haute, elle fait payer un refus a tout le monde ;
 * trop basse, elle prive les bons appareils de ce qu'ils savent faire. Aucune
 * API Android ne donne ce nombre — il ne se connait qu'en **essayant**.
 *
 * Ce magasin est la memoire de cet essai. L'appareil apprend une fois, et s'en
 * souvient.
 *
 * ## ⚠️ La signature, et pourquoi elle n'est pas decorative
 *
 * Le plafond depend de la **pile Bluetooth**, qui appartient au systeme. Une
 * mise a jour d'Android peut la changer dans les deux sens. Un chiffre appris en
 * 2026 et applique a un systeme de 2027 serait indiscernable d'une mesure
 * fraiche — la famille exacte des documents perimes de `CLAUDE.md`.
 *
 * `Build.FINGERPRINT` change a chaque build systeme installe : c'est ce qui fait
 * **oublier** l'ancienne mesure au lieu de la trainer.
 *
 * ⚠️ **On ne retient que ce qui a ete CONSTATE.** Rien ici n'est une valeur par
 * defaut : quand ce magasin ne sait pas, il le dit ([INCONNU]), et c'est
 * l'appelant qui choisit avec quoi commencer.
 */
object AdvertCapacityStore {

    /** Aucune mesure pour cet appareil et ce systeme. */
    const val INCONNU = 0

    private const val FICHIER = "neovibe_advert_capacity"
    private const val CLE_PLAFOND = "plafond"
    private const val CLE_SIGNATURE = "signature"

    private fun prefs(context: Context) =
        context.getSharedPreferences(FICHIER, Context.MODE_PRIVATE)

    /**
     * Le plafond appris pour cet appareil, ou [INCONNU].
     *
     * Rend [INCONNU] aussi quand le systeme a change depuis la mesure : mieux
     * vaut re-apprendre que raisonner sur un chiffre qui ne decrit plus rien.
     */
    fun lire(context: Context): Int {
        val p = prefs(context)
        if (p.getString(CLE_SIGNATURE, null) != signature()) return INCONNU
        return p.getInt(CLE_PLAFOND, INCONNU)
    }

    /** Retient [plafond], avec la signature du systeme qui l'a rendu vrai. */
    fun ecrire(context: Context, plafond: Int) {
        if (plafond <= 0) return
        prefs(context).edit()
            .putInt(CLE_PLAFOND, plafond)
            .putString(CLE_SIGNATURE, signature())
            .apply()
    }

    // ⚠️ **Pas d'`effacer()`, et c'est reflechi.** Contrairement a `PlanStore`,
    // rien ici n'appartient a un compte : c'est une propriete du MATERIEL. Un
    // changement d'utilisateur ne change pas la puce, et effacer obligerait le
    // suivant a re-apprendre — en payant un repli — pour rien. Le seul evenement
    // qui perime la mesure est une mise a jour du systeme, et c'est la signature
    // qui s'en charge.
    //
    // Une fonction ecrite « au cas ou » et que personne n'appelle est un reste
    // mort : elle finit par etre appelee par erreur, ou par decider d'une
    // architecture qu'on n'a pas choisie.

    private fun signature(): String = Build.FINGERPRINT
}
