package com.neovibe.neovibe.ble

import android.content.Context
import android.os.SystemClock
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * La vie du service radio, **ecrite sur le disque au fur et a mesure**.
 *
 * ## Le defaut que ce fichier corrige — test de nuit du 2026-09-13
 *
 * L'app a ete laissee ouverte a 03:08, ecran eteint, en charge. A 09:57 elle
 * est repartie de zero : `rawScans` avait BAISSE (1 997 → 776) et
 * `slotAlarmReveils` valait 0 apres sept heures. Le processus etait donc mort
 * dans la nuit — mais **on ne sait ni quand, ni pourquoi, ni si Android a
 * tente de le relancer** : tous les compteurs vivaient dans l'objet service, et
 * sont morts avec lui. `RAPPELS.md` #87 ③ (« la reprise apres qu'Android a
 * reellement tue le processus ») restait non prouve pour cette raison exacte :
 * **l'instrument mourait avec ce qu'il mesurait.**
 *
 * Ici, chaque evenement du cycle de vie est **ajoute a un fichier** au moment
 * ou il se produit : cree, demarre par l'app, relance par Android, reprise du
 * disque reussie ou non, alarme de creneau, memoire basse, detruit. Le fichier
 * survit au processus ; le rapport de diagnostic le relit tel quel.
 *
 * ## ⚠️ Ce qui est ecrit, et ce qui ne l'est JAMAIS
 *
 * Des evenements et des heures. **Aucun identifiant, aucun jeton, aucun ami,
 * aucune position.** Ce carnet dit « le service est mort a 04:12 », jamais
 * « qui etait la ».
 *
 * ## ⚠️ Deux horloges par ligne, et ce n'est pas decoratif
 *
 * - l'heure murale (`System.currentTimeMillis`) : pour aligner avec le journal
 *   Dart et les notes de Jay ;
 * - `up=` (`SystemClock.elapsedRealtime`, en secondes) : le temps depuis le
 *   dernier demarrage du telephone. **Il redescend si le telephone a
 *   redemarre** — c'est la seule facon de distinguer « Android a tue l'app »
 *   de « le telephone s'est eteint », deux pannes qui laissent exactement le
 *   meme rapport sans elle.
 *
 * ## Ce qu'il ne partage avec rien
 *
 * Un fichier a lui, distinct de `PlanStore` : le plan s'efface a chaque
 * demarrage voulu et a chaque arret voulu (il porte des jetons), le carnet
 * **ne s'efface jamais** — il se borne. Deux durees de vie, deux fichiers
 * (regle 2 de `CLAUDE.md`).
 *
 * ## Borne
 *
 * Passe [TAILLE_MAX], on garde la fin. A ~100 lignes par jour (96 alarmes +
 * quelques evenements), 24 Ko couvrent plusieurs jours.
 *
 * ⚠️ **Le `Context` ne sert qu'a trouver le fichier** ; tout le reste travaille
 * sur un `File`, pour etre eprouvable en test JVM — meme raison que
 * [PlanStore].
 */
object ServiceJournal {

    private const val NOM = "proximity_service.log"

    /** Au-dela, on ne garde que la fin. */
    const val TAILLE_MAX = 24 * 1024

    /** Ce qu'il reste apres une coupe : la moitie, sur une frontiere de ligne. */
    private const val TAILLE_APRES_COUPE = TAILLE_MAX / 2

    const val MARQUE_COUPE = "[…] plus ancien retiré"

    private fun fichier(context: Context) = File(context.filesDir, NOM)

    /** Ajoute une ligne. Ne leve jamais : un carnet qui casse le service qu'il decrit ne sert a rien. */
    fun note(context: Context, evenement: String, detail: String? = null) =
        note(
            fichier(context),
            evenement,
            detail,
            System.currentTimeMillis(),
            SystemClock.elapsedRealtime(),
        )

    fun note(
        cible: File,
        evenement: String,
        detail: String?,
        maintenantMillis: Long,
        uptimeMillis: Long,
    ) {
        val ligne = buildString {
            append(horodate(maintenantMillis))
            append(" up=")
            append(uptimeMillis / 1000)
            append("s ")
            append(evenement)
            if (!detail.isNullOrEmpty()) {
                append(" — ")
                append(detail)
            }
            append('\n')
        }
        runCatching {
            cible.appendText(ligne)
            if (cible.length() > TAILLE_MAX) coupe(cible)
        }
    }

    /** Le carnet entier, tel quel. Vide s'il n'existe pas ou ne se lit pas. */
    fun lire(context: Context): String = lire(fichier(context))

    fun lire(cible: File): String =
        runCatching { if (cible.exists()) cible.readText() else "" }.getOrDefault("")

    private fun coupe(cible: File) {
        val texte = cible.readText()
        val depart = texte.length - TAILLE_APRES_COUPE
        val frontiere = texte.indexOf('\n', depart.coerceAtLeast(0))
        val garde = if (frontiere < 0) "" else texte.substring(frontiere + 1)
        cible.writeText("$MARQUE_COUPE\n$garde")
    }

    private fun horodate(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT).format(Date(millis))
}
