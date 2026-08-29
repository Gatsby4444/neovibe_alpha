package com.neovibe.neovibe.ble

/**
 * Le PLAN d'emission, et le seul objet du natif qui sache quoi crier.
 *
 * ## Pourquoi il existe : le point H
 *
 * Le jeton diffuse depend du creneau de 15 minutes en cours. C'etait un
 * minuteur **Dart** qui calculait le suivant et le poussait a la radio. Or le
 * Dart meurt avec l'interface, pendant que ce service, lui, survit et garde la
 * radio.
 *
 * Consequence relevee le 2026-08-19 : des qu'Android detruisait l'activite,
 * l'identifiant emis **se figeait**. Passe une demi-heure il sortait de la
 * fenetre de tolerance et plus aucun ami ne reconnaissait l'appareil - alors
 * qu'il criait en permanence, avec la bonne cle. Et il devenait constant,
 * c'est-a-dire exactement le mouchard que la rotation par creneau existe pour
 * eviter.
 *
 * La cause n'est pas la cryptographie : c'est que **le natif dependait du Dart
 * pour savoir quoi emettre**. On la supprime en lui donnant plusieurs heures de
 * jetons d'avance. Il n'a plus qu'a lire l'heure et choisir.
 *
 * ## Ce que ce plan ne contient PAS
 *
 * Aucun secret. Les jetons sont des identifiants publics deja calcules : les
 * derober ne permet ni de nous suivre demain, ni d'en fabriquer d'autres. Toute
 * la cryptographie reste en Dart, et il n'y en a pas une ligne ici.
 *
 * ## Quand le plan est epuise
 *
 * On **arrete d'emettre**. C'est deliberement le contraire de ce que faisait
 * l'ancien code : reemettre le dernier jeton connu ne se voit pas, ne leve
 * rien, et laisse croire a une radio saine alors que plus personne ne nous
 * reconnait. Le silence, lui, se constate.
 */
class AdvertSchedule(
    /** Premier creneau couvert. */
    private val fromSlot: Long,
    /** Duree d'un creneau, en millisecondes. */
    private val slotMillis: Long,
    /** Nombre de creneaux couverts. */
    private val slotCount: Int,
    /** Nombre de jetons par creneau (amis + eventuel identifiant public). */
    private val perSlot: Int,
    /** Tous les jetons, a plat, creneau par creneau. */
    private val tokens: ByteArray,
    /** Longueur d'un jeton. */
    private val tokenLength: Int,
    /**
     * Le TYPE de chaque jeton, dans le meme ordre : public ou prive.
     *
     * ⚠️ **Fourni par le Dart, jamais deduit ici.** Lequel des jetons est
     * l'identifiant public est une regle produit (« le mode ping est ce qui
     * l'ajoute »), et elle vit d'un seul cote.
     */
    private val types: ByteArray,
) {
    val isEmpty: Boolean get() = slotCount <= 0 || perSlot <= 0

    /** Dernier instant couvert, en millisecondes depuis l'epoque. */
    val validUntilMillis: Long get() = (fromSlot + slotCount) * slotMillis

    fun covers(nowMillis: Long): Boolean {
        if (isEmpty) return false
        val slot = nowMillis / slotMillis
        return slot >= fromSlot && slot < fromSlot + slotCount
    }

    /**
     * Le jeton a emettre a [nowMillis], pour le [cursor]-ieme tour de cycle.
     *
     * Rend `null` si le plan ne couvre plus cet instant - a quoi l'appelant
     * repond en cessant d'emettre, jamais en rejouant l'ancien.
     */
    // ⚠️ **`typeAt` a ete SUPPRIME le 2026-08-29**, et pas seulement parce
    // qu'il n'avait plus d'appelant en production : sa reponse etait devenue
    // FAUSSE. Il indexait le curseur sur le creneau **complet**, alors que le
    // mode cycle parcourt desormais la liste **filtree** (voir
    // [tokensAt] avec `avecPublic`). Le curseur 0 pouvait donc y valoir
    // « public » pendant que la radio emettait un jeton d'ami.
    //
    // Un reste mort ment rarement ; un reste mort dont la semantique a bouge
    // ment toujours, et il ment avec l'assurance d'une methode publique.

    fun tokenAt(nowMillis: Long, cursor: Int): ByteArray? {
        if (!covers(nowMillis)) return null
        val slotOffset = (nowMillis / slotMillis - fromSlot).toInt()
        val which = if (perSlot == 1) 0 else Math.floorMod(cursor, perSlot)
        val start = (slotOffset * perSlot + which) * tokenLength
        if (start + tokenLength > tokens.size) return null
        return tokens.copyOfRange(start, start + tokenLength)
    }

    /**
     * **TOUS** les jetons du creneau qui couvre [nowMillis], avec leurs types.
     *
     * Rend `null` si le plan ne couvre plus cet instant - meme reponse que
     * [tokenAt] : on se tait plutot que de rejouer l'ancien.
     *
     * ## Pourquoi cette methode existe (2026-08-26)
     *
     * [tokenAt] ne rend qu'un jeton a la fois, parce que la radio n'en emettait
     * qu'un a la fois. Or **le mode cycle ne passe pas a l'echelle** : avec dix
     * amis, le jeton de chacun n'etait en l'air que 10 % du temps, et quelqu'un
     * qu'on croise trois secondes pouvait n'etre jamais vu. Le defaut s'aggravait
     * avec le nombre d'amis, et ne levait rien.
     *
     * Le moteur sait emettre plusieurs annonces simultanement : il lui faut donc
     * le creneau entier, pas un jeton choisi par un curseur.
     */
    fun tokensAt(nowMillis: Long): Pair<List<ByteArray>, ByteArray>? =
        tokensAt(nowMillis, avecPublic = true)

    /**
     * Le meme creneau, en choisissant si l'identifiant PUBLIC en fait partie.
     *
     * ## 🔴 Pourquoi ce parametre existe — 2026-08-29
     *
     * Le plan porte plusieurs heures de jetons d'avance, pour que le service
     * survive seul a la mort du Dart. C'est juste pour les jetons d'AMIS : un
     * ami reconnait tout seul, sans reseau, app fermee.
     *
     * L'identifiant PUBLIC, lui, ne vaut rien sans la balise que le Dart
     * republie au serveur, et qui meurt cinq minutes apres lui. L'appareil
     * continuait donc de le crier **jusqu'a soixante-dix minutes de plus** : un
     * identifiant que plus personne au monde ne pouvait traduire, mais que
     * n'importe quel scanner pouvait suivre.
     *
     * ⚠️ **Le plan ne decide pas s'il a le droit** — il ne sait rien du Dart,
     * ni du serveur, ni de l'heure du dernier signe de vie. Il execute. Qui
     * decide, c'est le service ; et il le decide au seul endroit par lequel un
     * jeton atteint la radio.
     *
     * Rend une liste **vide** — pas `null` — quand il ne restait que du public
     * et qu'on n'en veut pas : *le plan couvre cet instant, et il n'y a rien a
     * crier* est un message different de *le plan est epuise*. Les confondre
     * ferait annoncer une panne a la place d'un silence voulu.
     */
    fun tokensAt(nowMillis: Long, avecPublic: Boolean): Pair<List<ByteArray>, ByteArray>? {
        if (!covers(nowMillis)) return null
        val slotOffset = (nowMillis / slotMillis - fromSlot).toInt()
        val jetons = ArrayList<ByteArray>(perSlot)
        val leursTypes = ArrayList<Byte>(perSlot)
        for (i in 0 until perSlot) {
            val index = slotOffset * perSlot + i
            val start = index * tokenLength
            if (start + tokenLength > tokens.size) return null
            val type = if (index < types.size) types[index] else BleConstants.TYPE_PUBLIC
            if (!avecPublic && type == BleConstants.TYPE_PUBLIC) continue
            jetons.add(tokens.copyOfRange(start, start + tokenLength))
            leursTypes.add(type)
        }
        return Pair(jetons, leursTypes.toByteArray())
    }

    /** Combien de jetons differents sont emis par creneau. */
    val cycleLength: Int get() = perSlot

    // ------------------------------------------------------------------
    // Persistance — voir `PlanStore`
    // ------------------------------------------------------------------
    //
    // ⚠️ **Ces accesseurs existent pour ECRIRE le plan sur le disque, et pour
    // rien d'autre.** Ils rendent ce que le Dart a depose, tel quel : ce
    // fichier ne calcule toujours rien.

    val rawFromSlot: Long get() = fromSlot
    val rawSlotMillis: Long get() = slotMillis
    val rawSlotCount: Int get() = slotCount
    val rawTokenLength: Int get() = tokenLength
    val rawTokens: ByteArray get() = tokens

    /**
     * Le meme plan, **prive de l'identifiant public du ping**.
     *
     * ⚠️ **C'est la moitie du choix de Jay du 2026-08-28** : on persiste ce qui
     * fait le croisement entre amis, jamais ce qui rend decouvrable par des
     * inconnus. L'identifiant public repart d'une graine neuve a chaque
     * lancement — c'est ce qui empeche de relier deux sessions de decouverte —
     * et l'ecrire sur le disque le rendrait stable douze heures durant.
     *
     * Rend `null` s'il n'y a aucun jeton d'ami : il n'y a alors rien a
     * persister, et un fichier vide serait un plan qui ne fait plus rien.
     */
    fun friendsOnly(): AdvertSchedule? {
        if (isEmpty) return null
        val parCreneau = ArrayList<Int>(perSlot)
        for (i in 0 until perSlot) {
            if (types.getOrElse(i) { BleConstants.TYPE_PUBLIC } == BleConstants.TYPE_FRIEND) {
                parCreneau.add(i)
            }
        }
        if (parCreneau.isEmpty()) return null

        val sortie = ByteArray(slotCount * parCreneau.size * tokenLength)
        var pos = 0
        for (s in 0 until slotCount) {
            for (i in parCreneau) {
                val depart = (s * perSlot + i) * tokenLength
                if (depart + tokenLength > tokens.size) return null
                System.arraycopy(tokens, depart, sortie, pos, tokenLength)
                pos += tokenLength
            }
        }
        return AdvertSchedule(
            fromSlot = fromSlot,
            slotMillis = slotMillis,
            slotCount = slotCount,
            perSlot = parCreneau.size,
            tokens = sortie,
            tokenLength = tokenLength,
            types = ByteArray(slotCount * parCreneau.size) { BleConstants.TYPE_FRIEND },
        )
    }
}
