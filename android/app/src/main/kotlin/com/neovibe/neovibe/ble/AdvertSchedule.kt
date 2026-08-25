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
    /** Le type du jeton que [tokenAt] rendrait pour ce meme curseur. */
    fun typeAt(nowMillis: Long, cursor: Int): Byte {
        if (!covers(nowMillis)) return BleConstants.TYPE_PUBLIC
        val slotOffset = (nowMillis / slotMillis - fromSlot).toInt()
        val which = if (perSlot == 1) 0 else Math.floorMod(cursor, perSlot)
        val index = slotOffset * perSlot + which
        return if (index < types.size) types[index] else BleConstants.TYPE_PUBLIC
    }

    fun tokenAt(nowMillis: Long, cursor: Int): ByteArray? {
        if (!covers(nowMillis)) return null
        val slotOffset = (nowMillis / slotMillis - fromSlot).toInt()
        val which = if (perSlot == 1) 0 else Math.floorMod(cursor, perSlot)
        val start = (slotOffset * perSlot + which) * tokenLength
        if (start + tokenLength > tokens.size) return null
        return tokens.copyOfRange(start, start + tokenLength)
    }

    /** Combien de jetons differents sont emis par creneau. */
    val cycleLength: Int get() = perSlot
}
