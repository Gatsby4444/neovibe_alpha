package com.neovibe.neovibe.ble

/**
 * **Reconnaitre un ami sans le Dart, et sans rien savoir de lui.**
 *
 * ## Pourquoi ce fichier existe
 *
 * Depuis le plan d'emission ([AdvertSchedule]), le service DIFFUSE tout seul.
 * Mais il ne RECONNAISSAIT rien : l'appariement jeton -> ami vivait en Dart,
 * qui meurt avec l'interface. App fermee, l'appareil etait donc **vu sans
 * voir** — et le croisement, qui est justement fait pour le telephone dans la
 * poche, ne se produisait jamais.
 *
 * ## ⚠️ Ce que le natif N'APPREND PAS, et c'est deliberе
 *
 * La table ne contient **aucune identite** : ni nom, ni identifiant de compte,
 * ni cle. Elle associe un jeton a un **rang** (0, 1, 2...) dont seul le Dart
 * connait la signification. Un vidage memoire du service ne dit donc pas qui
 * sont vos amis — au mieux qu'il y en a N.
 *
 * Corollaire a ne pas perdre de vue : ce rang n'a de sens **que pour la table
 * qui l'a produit**. D'ou [tableId], renvoye avec chaque constat : si le Dart a
 * change de table entre-temps (ami ajoute, ami retire), il jette les constats
 * de l'ancienne au lieu de les attribuer a la mauvaise personne.
 *
 * ## ⚠️ Aucune cryptographie ici non plus
 *
 * Les jetons sont deja calcules. Le natif compare des octets, rien de plus.
 */

/** Un jeton attendu, et de qui. */
private class Attendu(val index: Int, val slot: Long)

/**
 * La table de reconnaissance : jeton attendu -> rang de l'ami.
 *
 * Construite a partir d'un tampon **a plat**, range creneau par creneau. A
 * 12 h et 50 amis : 48 x 50 x 16 = 38 Ko et ~2400 entrees. Une table de hachage
 * de cette taille se consulte en temps constant, a chaque annonce captee.
 */
class RecognitionTable(
    /** Identifiant de CETTE table. Renvoye avec chaque constat. */
    val tableId: Int,
    private val fromSlot: Long,
    private val slotMillis: Long,
    slotCount: Int,
    perSlot: Int,
    tokens: ByteArray,
    tokenLength: Int,
) {
    // ⚠️ **Ces champs existent pour ECRIRE la table sur le disque** (voir
    // `PlanStore`), et pour rien d'autre. Sans elle, un service repris apres la
    // mort du processus emettrait sans reconnaitre : vu sans voir.
    val rawFromSlot: Long = fromSlot
    val rawSlotMillis: Long = slotMillis
    val rawSlotCount: Int = slotCount
    val rawPerSlot: Int = perSlot
    val rawTokenLength: Int = tokenLength
    val rawTokens: ByteArray = tokens

    private val index = HashMap<String, Attendu>(slotCount * perSlot * 2)

    init {
        var pos = 0
        for (s in 0 until slotCount) {
            for (i in 0 until perSlot) {
                if (pos + tokenLength > tokens.size) break
                index[hex(tokens, pos, tokenLength)] = Attendu(i, fromSlot + s)
                pos += tokenLength
            }
        }
    }

    val size: Int get() = index.size

    /**
     * Rend le rang de l'ami si [advertId] est un jeton attendu **maintenant**.
     *
     * ⚠️ **La fenetre de creneau n'est pas une commodite, c'est une securite.**
     * Sans elle, un jeton capte ce matin et rejoue ce soir serait accepte : il
     * suffirait d'enregistrer une annonce pour fabriquer un croisement plus
     * tard. On exige donc que le creneau du jeton soit celui de l'instant, a un
     * pres — la meme tolerance d'horloge que partout ailleurs.
     */
    fun match(advertId: ByteArray, nowMillis: Long): Int? {
        val attendu = index[hex(advertId, 0, advertId.size)] ?: return null
        val creneau = nowMillis / slotMillis
        if (attendu.slot < creneau - 1 || attendu.slot > creneau + 1) return null
        return attendu.index
    }

    // ⚠️ **`validUntilMillis` a ete RETIRE le 2026-08-28** : aucun appelant, ni
    // dans le service, ni dans le pont, ni dans les tests. Il reprenait de plus
    // `slotCount` en parametre alors que la table en detient un — deux sources
    // pour une meme borne, dont la mauvaise etait la plus facile a appeler.

    private companion object {
        private val CHIFFRES = "0123456789abcdef".toCharArray()

        fun hex(bytes: ByteArray, offset: Int, length: Int): String {
            val out = CharArray(length * 2)
            for (i in 0 until length) {
                val v = bytes[offset + i].toInt() and 0xFF
                out[i * 2] = CHIFFRES[v ushr 4]
                out[i * 2 + 1] = CHIFFRES[v and 0x0F]
            }
            return String(out)
        }
    }
}

/** Un constat retenu par le natif, en attendant le retour du Dart. */
data class NativeSighting(
    val tableId: Int,
    val friendIndex: Int,
    val slot: Long,
    val rssi: Int,
    val txPower: Int,
)

/**
 * Ce que le service a constate pendant que le Dart etait absent.
 *
 * ## ⚠️ Deduplique par (ami, creneau), et borne
 *
 * L'advertising tourne a ~100 ms : un ami immobile produirait ~9 000 constats
 * identiques par creneau. On n'en garde qu'un — celui du **meilleur signal**,
 * parce que c'est celui qui decrit le mieux la rencontre.
 *
 * Et la borne n'est pas decorative : une memoire non bornee dans un service qui
 * vit des jours est une fuite, et elle ne se voit qu'au bout de longtemps.
 *
 * ## ⚠️ En memoire seulement
 *
 * Si Android tue le PROCESSUS (et pas seulement l'interface), ces constats sont
 * perdus. C'est assume : les ecrire sur le disque depuis le natif reviendrait a
 * poser hors du Dart une trace de qui a ete croise, pour rattraper un cas rare.
 */
class SightingBuffer(private val maxEntries: Int = 500) {
    private val retenus = LinkedHashMap<Long, NativeSighting>()

    val size: Int get() = retenus.size

    fun note(sighting: NativeSighting) {
        val cle = (sighting.friendIndex.toLong() shl 40) xor sighting.slot
        val existant = retenus[cle]
        if (existant != null) {
            // Meme ami, meme creneau : on garde le meilleur signal.
            if (sighting.rssi > existant.rssi) retenus[cle] = sighting
            return
        }
        if (retenus.size >= maxEntries) return
        retenus[cle] = sighting
    }

    /** Rend tout et vide. Le Dart devient seul responsable de ce qui sort. */
    fun drain(): List<NativeSighting> {
        val out = retenus.values.toList()
        retenus.clear()
        return out
    }

    fun clear() = retenus.clear()
}
