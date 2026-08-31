package com.neovibe.neovibe.ble

/**
 * **Ce qui est REELLEMENT en l'air, et depuis quel creneau.**
 *
 * ## 🔴 Le defaut que cette classe supprime — releve le 2026-08-29
 *
 * `AdvertisingSet.setAdvertisingData()` est **asynchrone**. Elle ne rend rien,
 * ne leve rien, et rapporte son sort dans `onAdvertisingDataSet(set, status)`.
 * Ce rappel n'etait pas ecrit : un refus de la pile Bluetooth ne se voyait donc
 * **nulle part**.
 *
 * Consequence, constatee a deux appareils : le jeu d'annonces continuait de
 * rayonner le **dernier jeton accepte**, celui d'un creneau revolu. En face,
 * `SightingBook.match` le rejetait sur la fenetre de creneau — l'appareil etait
 * entendu dix fois par seconde et reconnu zero fois. Et tout, du cote de
 * l'emetteur, disait que tout allait bien : `advertMode = parallele`,
 * `advertSetsOnAir = 2`, `advertTokensPerSlot = 2`.
 *
 * ⚠️ **C'est la meme famille que le defaut du 2026-08-29 matin**
 * (`advertSetsOnAir`) : *ce qu'on croit tenir* n'est pas *ce qui emet*. La seule
 * reponse qui vaille est de compter ce que la pile a **accepte**, jamais ce
 * qu'on lui a demande.
 *
 * ## Les trois etats d'un jeton, et pourquoi il en faut trois
 *
 * | Etat | Ce que ca veut dire |
 * |---|---|
 * | **demande** | ce que le plan veut crier a ce creneau |
 * | **en vol** | un ecrit est parti vers la pile, sans reponse encore |
 * | **confirme** | la pile a dit oui : c'est ce qui rayonne vraiment |
 *
 * Sans l'etat « en vol », deux ecrits successifs sur le meme jeu attribuent la
 * reponse du premier au second. Sans « confirme », on ne peut pas savoir qu'un
 * reecrit est inutile — et on reecrit alors toutes les trente secondes un
 * contenu qui ne change que tous les quarts d'heure, ce qui est precisement ce
 * qui fait refuser la pile.
 *
 * ⚠️ **Classe pure** : aucun appel Android, donc eprouvable
 * (`AdvertOnAirTest.kt`).
 */
class AdvertOnAir {
    /** Ce que le plan veut crier, par rang de jeu d'annonce. */
    private val demande = HashMap<Int, String>()

    /** Ecrits partis vers la pile, en attente de reponse. */
    private val enVol = HashMap<Int, String>()

    /** Ce que la pile a ACCEPTE. C'est la seule verite sur ce qui rayonne. */
    private val confirme = HashMap<Int, String>()

    private var repereDemande = REPERE_INCONNU
    private var repereConfirme = REPERE_INCONNU

    /**
     * Combien de fois la pile a refuse un contenu d'annonce.
     *
     * ⚠️ **Un zero ici est une mesure, pas une absence de mesure** — c'est
     * exactement ce qui manquait avant le 2026-08-29.
     */
    var refus = 0
        private set

    /**
     * Remet le compteur de refus a zero, au demarrage d'une session de radio.
     *
     * ⚠️ **Existe pour que TOUS les compteurs du diagnostic aient la meme
     * origine** (2026-08-31). `oublie()` ne le fait pas et ne doit pas le
     * faire : il est appele a chaque silence, et un refus survenu pendant la
     * session doit rester visible jusqu'a la fin de cette session.
     */
    fun reinitialiseRefus() {
        refus = 0
    }

    /**
     * Le jeu [index] a-t-il besoin qu'on lui ecrive [tokenHex] ?
     *
     * Rend `false` s'il le porte deja, **ou** si un ecrit du meme contenu est
     * en vol : reecrire pour rien est ce qui use la pile.
     */
    fun besoinDEcrire(index: Int, tokenHex: String): Boolean =
        confirme[index] != tokenHex && enVol[index] != tokenHex

    /**
     * On s'apprete a poser [tokens] — dans l'ordre des jeux — pour [repere].
     *
     * [repere] est un nombre opaque pour cette classe : le service y met le
     * creneau courant. Le comparer a celui de l'instant est ce qui repond a la
     * seule question qui compte, *« crie-t-on encore le jeton d'il y a une
     * heure ? »*.
     */
    fun noteDemande(tokens: List<String>, repere: Long) {
        demande.clear()
        tokens.forEachIndexed { rang, jeton -> demande[rang] = jeton }
        repereDemande = repere
        // ⚠️ **Le seul endroit qui PERIME une confirmation, et il ne sert que
        // pour les rangs DISPARUS.**
        //
        // Un rang dont le jeton a change est deja traite par [majRepere], qui
        // compare des valeurs. Ce qu'il ne peut pas voir, c'est un jeu qui
        // n'est plus demande du tout — le plan passe de deux jetons a un quand
        // « Croiser mes amis » s'eteint. Sans cette ligne, `confirme` garderait
        // le rang 1 pour toujours, les tailles ne concorderaient plus jamais, et
        // le repere resterait bloque sur « on ne sait pas » sans qu'aucun
        // reecrit ne vienne le debloquer.
        //
        // ⚠️ **Verifie a l'envers** (2026-08-29) : retiree, `un plan qui
        // retrecit ne bloque pas le repere` tombe.
        confirme.keys.toList().forEach { rang ->
            if (!demande.containsKey(rang)) confirme.remove(rang)
        }
        // 🔴 **ET LES ECRITS EN VOL DES RANGS DISPARUS — corrige le 2026-08-31.**
        //
        // Seul `confirme` etait purge. Un rang qui disparait laissait donc son
        // entree dans `enVol` **pour toujours** : rien ne la retire, puisque ni
        // `noteConfirme` ni `noteRefus` ne seront jamais appeles pour un jeu
        // qu'on n'a plus.
        //
        // Consequence quand le rang revient avec le meme jeton — ce qui arrive
        // des qu'on eteint puis rallume « Croiser mes amis » dans le meme
        // creneau : [besoinDEcrire] repond `false` (« un ecrit du meme contenu
        // est en vol »), l'ecriture est sautee, `confirme` reste vide, et
        // [repereEnLAir] reste bloque sur [REPERE_INCONNU].
        //
        // ⚠️ Le diagnostic affichait alors `advertSlotDrift = -1` — « on ne sait
        // pas » — sur une emission parfaitement saine. L'instrument ecrit pour
        // trouver le defaut du 2026-08-29 devenait illisible apres un
        // aller-retour d'interrupteur.
        enVol.keys.toList().forEach { rang ->
            if (!demande.containsKey(rang)) enVol.remove(rang)
        }
        majRepere()
    }

    /** Un ecrit vient de partir vers la pile pour le jeu [index]. */
    fun noteEcrit(index: Int, tokenHex: String) {
        enVol[index] = tokenHex
    }

    /** La pile a ACCEPTE le dernier ecrit du jeu [index]. */
    fun noteConfirme(index: Int) {
        val jeton = enVol.remove(index) ?: return
        confirme[index] = jeton
        majRepere()
    }

    /**
     * La pile a REFUSE le dernier ecrit du jeu [index].
     *
     * ⚠️ **Il n'y a rien a defaire ici, et c'est une propriete, pas un oubli.**
     * Une confirmation ne survit jamais a un changement de jeton : [majRepere]
     * compare des valeurs, et [noteDemande] a deja retire les rangs disparus.
     * Le rang refuse est donc **deja** absent de `confirme` — on ne peut pas
     * ecrire un jeton deja confirme, [besoinDEcrire] l'interdit.
     *
     * ⚠️ **Une premiere version retirait quand meme `confirme[index]`.** Le
     * contre-test l'a montree morte : le defaut reintroduit, aucun test ne
     * tombait. Un garde-fou qu'aucune execution n'atteint n'est pas une
     * securite, c'est une seconde regle a maintenir — et c'est celle-la qui
     * finit par contredire la premiere.
     */
    fun noteRefus(index: Int) {
        enVol.remove(index)
        refus++
        majRepere()
    }

    /** Les annonces sont tombees : plus rien n'est en l'air, et on le dit. */
    fun oublie() {
        demande.clear()
        enVol.clear()
        confirme.clear()
        repereDemande = REPERE_INCONNU
        repereConfirme = REPERE_INCONNU
    }

    /**
     * Le repere des jetons **entierement** en l'air, [REPERE_INCONNU] tant
     * qu'un seul jeu manque a l'appel.
     *
     * ⚠️ **Tout ou rien, et c'est voulu.** Un appareil dont le jeton public est
     * a jour mais dont le jeton d'ami date d'une heure n'est pas « a moitie
     * visible » : il est invisible de ses amis, et c'est la moitie qui compte.
     * Une moyenne aurait cache exactement le cas qu'on cherche.
     */
    val repereEnLAir: Long get() = repereConfirme

    private fun majRepere() {
        val complet = demande.isNotEmpty() &&
            confirme.size == demande.size &&
            demande.all { (rang, jeton) -> confirme[rang] == jeton }
        repereConfirme = if (complet) repereDemande else REPERE_INCONNU
    }

    companion object {
        /** Aucun jeu de jetons n'est integralement confirme en l'air. */
        const val REPERE_INCONNU = -1L

        /** L'ecriture hexadecimale d'un jeton, seule cle de comparaison. */
        fun hex(token: ByteArray): String {
            val out = StringBuilder(token.size * 2)
            for (b in token) {
                val v = b.toInt() and 0xFF
                out.append(CHIFFRES[v ushr 4])
                out.append(CHIFFRES[v and 0x0F])
            }
            return out.toString()
        }

        private val CHIFFRES = "0123456789abcdef".toCharArray()
    }
}
