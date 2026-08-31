package com.neovibe.neovibe

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.File
import java.io.IOException

/**
 * La source de données que le lecteur interroge : elle lit **directement** le
 * format scellé `NVC1`, sans serveur, sans socket, et sans jamais écrire de
 * clair sur le disque.
 *
 * ### Ce qu'elle remplace
 *
 * Jusqu'à la v0.9.55, un serveur HTTP local sur `127.0.0.1` déchiffrait en Dart
 * et servait les octets au lecteur. Il fallait un jeton pour qu'aucune autre
 * application du téléphone ne devine l'URL, et une exception `cleartext` dans
 * le manifeste pour qu'Android accepte du HTTP en clair. **Trois pièces pour
 * un besoin qui n'en demandait aucune** : le lecteur peut lire notre format
 * lui-même.
 *
 * ExoPlayer appelle [open] à chaque déplacement dans la vidéo, avec la position
 * voulue. Comme la position d'un bloc se calcule (voir
 * `docs/format-media-scelle.md`), un saut ne coûte qu'une lecture disque et le
 * déchiffrement d'un seul bloc.
 *
 * Une instance sert **un** lecteur, sur le fil de chargement d'ExoPlayer. Elle
 * n'est pas sûre en accès concurrent, et n'a pas à l'être.
 */
@UnstableApi
class SealedDataSource(
    private val newReader: () -> SealedChunkReader,
    /**
     * Prevenus quand cette source **ouvre** et **ferme** son fichier.
     *
     * Ils servent a la fabrique, qui ne doit tenir que les sources ayant un
     * descripteur ouvert. Voir [Factory.created].
     */
    private val aLOuverture: (SealedDataSource) -> Unit = {},
    private val aLaFermeture: (SealedDataSource) -> Unit = {},
) : DataSource {

    /** Le schéma n'existe que pour donner une URI au lecteur ; rien ne la résout. */
    companion object {
        val URI: Uri = Uri.parse("neovibe://scelle")
    }

    private var reader: SealedChunkReader? = null
    private var position = 0L
    private var remaining = 0L
    private var opened = false

    private val listeners = mutableListOf<TransferListener>()

    override fun addTransferListener(transferListener: TransferListener) {
        listeners.add(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val reader = this.reader ?: newReader().also { this.reader = it }
        position = dataSpec.position
        if (position > reader.plainLength) {
            throw IOException("position hors du média : $position > ${reader.plainLength}")
        }
        remaining = if (dataSpec.length == C.LENGTH_UNSET.toLong()) {
            reader.plainLength - position
        } else {
            minOf(dataSpec.length, reader.plainLength - position)
        }
        opened = true
        aLOuverture(this)
        listeners.forEach { it.onTransferStart(this, dataSpec, /* isNetwork= */ false) }
        return remaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val reader = this.reader ?: throw IOException("source non ouverte")

        val want = minOf(length.toLong(), remaining).toInt()
        val read = reader.read(position, buffer, offset, want)
        if (read <= 0) return C.RESULT_END_OF_INPUT

        position += read
        remaining -= read
        return read
    }

    override fun getUri(): Uri = URI

    override fun close() {
        if (opened) {
            opened = false
            listeners.forEach { it.onTransferEnd(this, DataSpec(URI), /* isNetwork= */ false) }
        }
        // Le fichier est refermé ici, et pas seulement à [release] : ExoPlayer
        // ferme et rouvre la source à chaque déplacement dans la vidéo, et
        // garder le descripteur ouvert entre-temps les ferait s'accumuler sur
        // une longue lecture. Le rouvrir coûte une ouverture et 16 octets — et
        // le cache de bloc n'aurait de toute façon rien gardé d'utile après un
        // saut.
        reader?.close()
        reader = null
        aLaFermeture(this)
    }

    /** Filet : ferme le fichier d'une source qu'ExoPlayer n'aurait pas refermée. */
    fun release() {
        reader?.close()
        reader = null
        aLaFermeture(this)
    }

    /**
     * Fabrique une source par lecteur — ExoPlayer en réclame une à la demande.
     *
     * [newReader] décide **d'où viennent les octets** : un fichier entier sur
     * l'appareil, ou un cache partiel qui se remplit par intervalles au fur et
     * à mesure. Ni cette source ni le lecteur vidéo ne font la différence.
     */
    class Factory(private val newReader: () -> SealedChunkReader) : DataSource.Factory {
        /**
         * Les sources qui ont un fichier OUVERT, pour pouvoir les fermer
         * ensemble : une source oubliée garde un descripteur de fichier ouvert.
         *
         * ## 🔴 Ce qu'elle contenait avant le 2026-08-31
         *
         * **Toutes les sources jamais créées**, et rien ne les en retirait
         * avant [releaseAll]. Or ExoPlayer réclame une source à la demande — en
         * pratique une par déplacement dans la vidéo. La liste grandissait donc
         * avec le nombre de sauts, en gardant des objets qui avaient déjà tout
         * refermé.
         *
         * Ce n'était pas une fuite de descripteurs : chaque source ferme bien
         * son fichier dans [close]. C'était la liste qui ne correspondait plus
         * à ce qu'elle prétendait décrire.
         *
         * ⚠️ **Elle suit maintenant l'ouverture, pas la création.** Une source
         * y entre quand elle ouvre son fichier et en sort quand elle le ferme :
         * son contenu est donc, à tout instant, exactement l'ensemble des
         * fichiers ouverts. C'est ce que le filet doit refermer, et rien de
         * plus.
         */
        private val created = mutableSetOf<SealedDataSource>()

        override fun createDataSource(): DataSource = SealedDataSource(
            newReader,
            aLOuverture = { created.add(it) },
            aLaFermeture = { created.remove(it) },
        )

        fun releaseAll() {
            // ⚠️ On copie AVANT de libérer : `release()` retire de `created`,
            // et modifier une collection pendant qu'on la parcourt lève.
            val ouvertes = created.toList()
            created.clear()
            ouvertes.forEach { it.release() }
        }
    }
}
