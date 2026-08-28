package com.neovibe.neovibe.ble

import android.content.Context
import java.io.File
import java.nio.ByteBuffer

/**
 * Ce que le service garde **sur le disque** pour survivre a la mort du
 * processus.
 *
 * ## Le defaut que ce fichier corrige — audit du 2026-08-28
 *
 * Le plan d'emission vivait uniquement en memoire. Quand Android recuperait le
 * processus — pression memoire, ou un gestionnaire de batterie agressif —, le
 * service redemarrait sans son identifiant, disait « rouvre l'app » et
 * s'arretait. **« Le croisement fonctionne app fermee » etait donc vrai tant
 * que le PROCESSUS vivait, pas tant que le telephone etait allume** : une nuit
 * entiere n'etait pas garantie.
 *
 * ## ⚠️ Ce qui est ecrit, et ce qui ne l'est JAMAIS
 *
 * Decision de Jay, 2026-08-28 : **les jetons d'AMIS seulement.**
 *
 * | | Ecrit ? | Pourquoi |
 * |---|---|---|
 * | jetons de paire (amis) | **oui** | c'est eux qui font le croisement app fermee |
 * | table de reconnaissance | **oui** | sans elle, l'appareil serait vu sans voir |
 * | identifiant PUBLIC du ping | **non** | il repart de zero a chaque lancement, et c'est ce qui empeche de relier deux sessions de decouverte |
 *
 * ⚠️ **Consequence assumee** : apres une reprise depuis le disque, l'appareil
 * croise ses amis mais **n'est pas decouvrable par des inconnus** tant que
 * l'app n'a pas ete rouverte. C'est le prix choisi, et il est **visible** :
 * `stats()` publie `resumedFromDisk`.
 *
 * ## ⚠️ Aucun secret n'est ecrit
 *
 * Ce sont des identifiants **deja calcules**, ceux-la memes qui sont cries en
 * clair sur les ondes. Les derober ne permet ni d'en fabriquer d'autres, ni de
 * remonter aux cles : toute la cryptographie reste en Dart, dans le Keystore.
 * Ce qu'ils donnent a qui lit le disque, c'est **douze heures de jetons a
 * l'avance pour cet appareil** — la meme information qu'obtiendrait quelqu'un
 * qui resterait a cote de lui pendant douze heures.
 *
 * ## ⚠️ Et il s'efface
 *
 * Le fichier est supprime a **chaque demarrage demande par le Dart** (qui
 * s'apprete a en deposer un neuf) et a **chaque arret voulu**. C'est ce qui
 * empeche un compte de laisser derriere lui des jetons que le suivant ferait
 * crier — la fuite exacte que l'effacement du carnet avait ferme cote Dart.
 */
object PlanStore {

    private const val MAGIC = "NVPLAN2"

    private fun fichier(context: Context) = File(context.filesDir, "proximity_plan.bin")

    /** Efface le plan persiste. Sans bruit s'il n'y en a pas. */
    fun effacer(context: Context) {
        runCatching { fichier(context).delete() }
    }

    /**
     * Ecrit le plan (amis seulement) et la table.
     *
     * Rend `false` si l'un des deux manque : on n'ecrit **rien de partiel**.
     * Un plan sans table ferait un appareil vu sans voir, et une table sans
     * plan un appareil qui voit sans etre vu — les deux se deposent ensemble
     * ou pas du tout.
     */
    fun ecrire(context: Context, plan: AdvertSchedule?, table: RecognitionTable?): Boolean {
        val amis = plan?.friendsOnly()
        if (amis == null || table == null) {
            effacer(context)
            return false
        }
        return runCatching {
            val entete = MAGIC.toByteArray(Charsets.US_ASCII)
            val buffer = ByteBuffer.allocate(
                entete.size +
                    8 + 8 + 4 + 4 + 4 + // plan : fromSlot, slotMillis, slotCount, perSlot, tokenLength
                    4 + amis.rawTokens.size + // longueur + jetons
                    4 + 8 + 8 + 4 + 4 + 4 + // table : tableId, fromSlot, slotMillis, slotCount, perSlot, tokenLength
                    4 + table.rawTokens.size,
            )
            buffer.put(entete)
            buffer.putLong(amis.rawFromSlot)
            buffer.putLong(amis.rawSlotMillis)
            buffer.putInt(amis.rawSlotCount)
            buffer.putInt(amis.cycleLength)
            buffer.putInt(amis.rawTokenLength)
            buffer.putInt(amis.rawTokens.size)
            buffer.put(amis.rawTokens)
            buffer.putInt(table.tableId)
            buffer.putLong(table.rawFromSlot)
            buffer.putLong(table.rawSlotMillis)
            buffer.putInt(table.rawSlotCount)
            buffer.putInt(table.rawPerSlot)
            buffer.putInt(table.rawTokenLength)
            buffer.putInt(table.rawTokens.size)
            buffer.put(table.rawTokens)
            fichier(context).writeBytes(buffer.array())
            true
        }.getOrDefault(false)
    }

    /** Ce qu'on a relu du disque, ou `null` si rien d'exploitable. */
    data class Repris(val plan: AdvertSchedule, val table: RecognitionTable)

    /**
     * Relit le plan. Rend `null` si le fichier manque, est illisible, d'une
     * autre version, ou **ne couvre plus l'instant present**.
     *
     * ⚠️ **Un plan perime est rendu `null`, jamais « au mieux ».** Emettre des
     * jetons que plus personne n'attend est indiscernable d'une radio saine
     * tout en ne se faisant reconnaitre par personne — c'est le point H, en
     * plus silencieux. Le silence, lui, se constate.
     */
    fun relire(context: Context, nowMillis: Long): Repris? = runCatching {
        val f = fichier(context)
        if (!f.exists()) return null
        val buffer = ByteBuffer.wrap(f.readBytes())
        val entete = ByteArray(MAGIC.length)
        buffer.get(entete)
        if (String(entete, Charsets.US_ASCII) != MAGIC) return null

        val planFromSlot = buffer.long
        val planSlotMillis = buffer.long
        val planSlotCount = buffer.int
        val planPerSlot = buffer.int
        val planTokenLength = buffer.int
        val planTokens = ByteArray(buffer.int)
        buffer.get(planTokens)

        val tableId = buffer.int
        val tableFromSlot = buffer.long
        val tableSlotMillis = buffer.long
        val tableSlotCount = buffer.int
        val tablePerSlot = buffer.int
        val tableTokenLength = buffer.int
        val tableTokens = ByteArray(buffer.int)
        buffer.get(tableTokens)

        // ⚠️ **Tout est de type AMI** : le fichier n'en contient pas d'autres.
        val types = ByteArray(planSlotCount * planPerSlot) { BleConstants.TYPE_FRIEND }
        val plan = AdvertSchedule(
            fromSlot = planFromSlot,
            slotMillis = planSlotMillis,
            slotCount = planSlotCount,
            perSlot = planPerSlot,
            tokens = planTokens,
            tokenLength = planTokenLength,
            types = types,
        )
        if (!plan.covers(nowMillis)) return null

        Repris(
            plan,
            RecognitionTable(
                tableId = tableId,
                fromSlot = tableFromSlot,
                slotMillis = tableSlotMillis,
                slotCount = tableSlotCount,
                perSlot = tablePerSlot,
                tokens = tableTokens,
                tokenLength = tableTokenLength,
            ),
        )
    }.getOrNull()
}
