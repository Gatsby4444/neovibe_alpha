package com.neovibe.neovibe.ble

/** Une presence TERMINEE, telle que le service l'a vue. */
data class NativePresence(
    val tableId: Int,
    val friendIndex: Int,
    val debutMillis: Long,
    val finMillis: Long,
    val detections: Int,
)

/**
 * **Combien de temps un ami a ete la, et non plus seulement « il etait la ».**
 *
 * ## 🔴 Pourquoi ce fichier existe — refonte des waves du 2026-08-30
 *
 * Les regles decidees par Jay ne se prononcent plus sur une detection isolee :
 * elles regardent la **duree** d'un contact, et ce qui s'est passe deux heures
 * avant et une heure apres. [SightingBuffer], lui, dedupliquait par
 * `(ami, creneau)` : il repondait « vu pendant le quart d'heure de 14h15 », ce
 * qui ne permet de repondre a **aucune** des deux regles.
 *
 * ⚠️ **Le natif AVAIT l'information et la jetait.** Il voit chaque annonce ;
 * c'est la deduplication qui effacait la duree. Ici on ne garde que deux dates
 * et un compteur par presence — quelques dizaines d'octets — et la question
 * devient repondable meme quand le Dart ne recoit plus rien.
 *
 * ## ⚠️ Pourquoi le natif est la SEULE source des presences
 *
 * Le Dart sait aussi mesurer une presence (`PeerSession`), mais seulement
 * pendant que le pont Flutter est attache : activite detruite, les annonces
 * sont mises de cote et rejouees, et `peer_network` jette tout scan de plus de
 * cinq secondes. Deux mesures d'un meme fait, dont une avec des trous, c'est
 * **deux verites a tenir d'accord** — et c'est celle qui a des trous qui aurait
 * gagne en silence, puisque rien ne les distingue une fois ecrites.
 *
 * ## ⚠️ Le seuil de coupure DESCEND du Dart
 *
 * `gapMillis` n'est pas choisi ici : c'est `PresenceRules.forgetAfter`, envoye
 * avec la table de reconnaissance. Le recopier aurait fait deux definitions de
 * « la presence est terminee », et le jour ou l'une bouge, les durees mesurees
 * de chaque cote cessent de vouloir dire la meme chose.
 *
 * ## ⚠️ Classe pure
 *
 * Aucun appel Android, aucune horloge a elle : l'instant lui est passe. C'est
 * ce qui la rend eprouvable (`PresenceLogTest.kt`) — et ce code tourne **au
 * seul moment ou personne ne regarde**.
 */
class PresenceLog(private val maxEntries: Int = 200) {

    private class EnCours(
        val tableId: Int,
        val debut: Long,
        var fin: Long,
        var detections: Int,
    )

    /** Une presence en cours par rang d'ami. */
    private val enCours = HashMap<Int, EnCours>()

    private val terminees = ArrayList<NativePresence>()

    /**
     * Au-dela de ce silence, la presence est finie et la suivante recommence.
     *
     * Valeur d'attente sensee tant que le Dart n'a rien depose : elle vaut
     * `PresenceRules.forgetAfter`. ⚠️ **Elle ne fait pas autorite** — elle
     * evite seulement qu'un service reparti du disque avant tout depot mesure
     * n'importe quoi.
     */
    @Volatile
    var gapMillis: Long = GAP_PAR_DEFAUT

    companion object {
        /** `PresenceRules.forgetAfter`, en attendant le depot du Dart. */
        const val GAP_PAR_DEFAUT = 30_000L
    }

    val enCoursCount: Int get() = enCours.size
    val termineesCount: Int get() = terminees.size

    /** Un ami vient d'etre reconnu, a [atMillis]. */
    fun note(tableId: Int, friendIndex: Int, atMillis: Long) {
        val courante = enCours[friendIndex]
        if (courante == null) {
            enCours[friendIndex] = EnCours(tableId, atMillis, atMillis, 1)
            return
        }
        // ⚠️ **Un changement de table coupe la presence**, meme sans silence.
        // Le rang n'a de sens que pour la table qui l'a produit : prolonger
        // au-dela attribuerait la fin d'une presence a quelqu'un d'autre.
        if (courante.tableId != tableId || atMillis - courante.fin > gapMillis) {
            fermer(friendIndex, courante)
            enCours[friendIndex] = EnCours(tableId, atMillis, atMillis, 1)
            return
        }
        // Les annonces peuvent arriver dans le desordre : on ne recule jamais.
        if (atMillis > courante.fin) courante.fin = atMillis
        courante.detections++
    }

    /**
     * Rend les presences terminees, et **vide**.
     *
     * [nowMillis] sert a fermer celles qui n'ont plus rien donne depuis
     * [gapMillis] : sans lui, une presence qui se termine pendant que le Dart
     * est absent resterait ouverte pour toujours, et le contact ne serait
     * jamais juge.
     */
    fun drain(nowMillis: Long): List<NativePresence> {
        for ((rang, courante) in enCours.entries.toList()) {
            if (nowMillis - courante.fin > gapMillis) fermer(rang, courante)
        }
        val out = terminees.toList()
        terminees.clear()
        return out
    }

    fun clear() {
        enCours.clear()
        terminees.clear()
    }

    private fun fermer(friendIndex: Int, presence: EnCours) {
        enCours.remove(friendIndex)
        // ⚠️ **On jette le PLUS ANCIEN, pas le plus recent.** Refuser les
        // nouvelles entrees — ce que fait [SightingBuffer] — perdrait justement
        // les contacts que la regle doit juger : elle ne regarde que les trois
        // dernieres heures.
        if (terminees.size >= maxEntries) terminees.removeAt(0)
        terminees.add(
            NativePresence(
                tableId = presence.tableId,
                friendIndex = friendIndex,
                debutMillis = presence.debut,
                finMillis = presence.fin,
                detections = presence.detections,
            ),
        )
    }
}
