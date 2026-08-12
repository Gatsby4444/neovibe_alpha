package com.neovibe.neovibe

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer

/**
 * La disposition d'un média scellé, déduite de son en-tête.
 *
 * Tout ce qui suit repose sur une seule propriété du format : **la position
 * d'un bloc se calcule**. C'est elle qui permet de demander au serveur
 * exactement les octets d'un bloc, sans index à télécharger d'abord, et de
 * garder un cache **partiel** sans tenir de table de correspondance.
 *
 * Voir `docs/format-media-scelle.md`.
 */
class SealedLayout(val chunkSize: Int, val plainLength: Long) {

    /** Taille scellée d'un bloc plein : le clair plus les 28 octets d'AES-GCM. */
    val stride: Long = chunkSize.toLong() + SealedChunkReader.OVERHEAD

    val chunkCount: Long =
        if (plainLength == 0L) 0 else (plainLength + chunkSize - 1) / chunkSize

    /** Où commence le bloc [index] dans le fichier scellé. */
    fun sealedOffset(index: Long): Long = SealedChunkReader.HEADER_SIZE + index * stride

    /** Taille scellée du bloc [index] — pleine, sauf le dernier. */
    fun sealedSizeOf(index: Long): Int {
        val plain = minOf(chunkSize.toLong(), plainLength - index * chunkSize)
        return (plain + SealedChunkReader.OVERHEAD).toInt()
    }

    val sealedLength: Long
        get() = if (chunkCount == 0L) {
            SealedChunkReader.HEADER_SIZE.toLong()
        } else {
            sealedOffset(chunkCount - 1) + sealedSizeOf(chunkCount - 1)
        }
}

/**
 * D'où viennent les octets **scellés** d'un média.
 *
 * Cette abstraction est le point de bascule du chantier « livraison » : le
 * lecteur de blocs ([SealedChunkReader]) ne sait plus si le média est entier
 * sur l'appareil ou en train d'arriver du réseau. Ajouter le streaming n'a donc
 * demandé aucun changement au déchiffrement, ni au format, ni au lecteur vidéo.
 */
abstract class SealedChunkStore : Closeable {

    /** Renseignée par [open]. */
    lateinit var layout: SealedLayout
        protected set

    /** Lit l'en-tête et prépare la lecture. À appeler avant tout le reste. */
    abstract fun open()

    /** Les octets scellés du bloc [index], en entier. */
    abstract fun sealedChunk(index: Long): ByteArray

    protected fun parseHeader(header: ByteArray): SealedLayout {
        if (header.size < SealedChunkReader.HEADER_SIZE) {
            throw IOException("en-tête NVC1 tronqué")
        }
        val buffer = ByteBuffer.wrap(header) // gros-boutiste
        if (buffer.int != MAGIC) throw IOException("ce fichier n'est pas au format NVC1")
        val chunkSize = buffer.int
        val plainLength = buffer.long
        if (chunkSize <= 0 || plainLength < 0) {
            throw IOException("en-tête NVC1 incohérent : bloc=$chunkSize, longueur=$plainLength")
        }
        return SealedLayout(chunkSize, plainLength)
    }

    companion object {
        const val MAGIC = 0x4E564331 // 'NVC1'

        /**
         * Ce qu'on demande au serveur du premier coup : l'en-tête **et** le
         * premier bloc, en supposant la taille de bloc habituelle.
         *
         * L'en-tête seul tiendrait en 16 octets, mais il faudrait alors un
         * deuxième aller-retour pour la première image — et un aller-retour
         * mobile coûte 100 à 200 ms sur une cible de 300. La supposition est
         * vérifiée dès l'en-tête lu : si elle est fausse, on refait la demande
         * proprement.
         */
        const val PRIMING_BYTES: Long = 16L + 256L * 1024L + 28L
    }
}

/** Le média est entier sur l'appareil : le cas d'un contenu déjà téléchargé. */
class LocalChunkStore(file: File) : SealedChunkStore() {

    private val raf = RandomAccessFile(file, "r")

    override fun open() {
        val header = ByteArray(SealedChunkReader.HEADER_SIZE)
        raf.seek(0)
        raf.readFully(header)
        layout = parseHeader(header)
        // Une taille inattendue signale une troncature : mieux vaut refuser
        // d'ouvrir que rendre un flux qui s'arrêtera au milieu sans rien dire.
        if (raf.length() != layout.sealedLength) {
            throw IOException("média scellé incomplet : ${raf.length()} au lieu de ${layout.sealedLength}")
        }
    }

    override fun sealedChunk(index: Long): ByteArray {
        val bytes = ByteArray(layout.sealedSizeOf(index))
        raf.seek(layout.sealedOffset(index))
        raf.readFully(bytes)
        return bytes
    }

    override fun close() = raf.close()
}

/**
 * Le média arrive **au fur et à mesure**, et ce qui est arrivé reste.
 *
 * ### Ce que ça change
 *
 * Jusqu'ici, voir une vidéo pour la première fois demandait de la télécharger
 * **en entier** — 6,5 Mo pour 15 s à 3,5 Mbit/s, soit près d'une minute sur un
 * réseau lent. Ici, le lecteur ne réclame que les blocs qu'il traverse, et la
 * première image ne dépend plus que du premier d'entre eux.
 *
 * ### Le cache partiel
 *
 * Deux fichiers : les octets, à leur **position définitive** dans le fichier
 * scellé (donc un fichier creux qui se remplit), et une carte des blocs
 * présents. Comme la position d'un bloc se calcule, il n'y a **aucune table de
 * correspondance à tenir** — la carte se réduit à un octet par bloc, soit une
 * centaine d'octets pour une minute de vidéo.
 *
 * Un média complètement téléchargé est alors, octet pour octet, le fichier
 * scellé d'origine : le même que celui qu'un [LocalChunkStore] lirait.
 */
class RemoteChunkStore(
    private val data: File,
    private val map: File,
    private val fetcher: RangeFetcher,
) : SealedChunkStore() {

    /** Nombre de requêtes réseau émises — sert aux tests et à la mesure. */
    var requests = 0
        private set

    private var raf: RandomAccessFile? = null
    private var present = ByteArray(0)

    override fun open() {
        data.parentFile?.mkdirs()
        val file = RandomAccessFile(data, "rw").also { raf = it }

        // Le cache connaît déjà ce média ? L'en-tête est alors sur l'appareil,
        // et l'ouverture ne coûte rien au réseau.
        if (map.exists() && file.length() >= SealedChunkReader.HEADER_SIZE) {
            val stored = map.readBytes()
            if (stored.isNotEmpty() && stored[0].toInt() == 1) {
                val header = ByteArray(SealedChunkReader.HEADER_SIZE)
                file.seek(0)
                file.readFully(header)
                layout = parseHeader(header)
                present = stored.copyOfRange(1, stored.size)
                ensureSized(file)
                return
            }
        }

        // Premier contact : en-tête et premier bloc en UNE requête.
        val primed = fetcher.fetch(0, PRIMING_BYTES - 1)
        requests++
        layout = parseHeader(primed)
        present = ByteArray(layout.chunkCount.toInt())
        ensureSized(file)

        file.seek(0)
        file.write(primed, 0, minOf(primed.size, SealedChunkReader.HEADER_SIZE))

        // La supposition sur la taille de bloc était-elle bonne ? Si oui, le
        // premier bloc est déjà là et la première image ne coûtera rien de plus.
        if (layout.chunkCount > 0) {
            val firstSize = layout.sealedSizeOf(0)
            val head = SealedChunkReader.HEADER_SIZE
            if (primed.size - head >= firstSize) {
                store(0, primed.copyOfRange(head, head + firstSize))
            }
        }
        saveMap()
    }

    override fun sealedChunk(index: Long): ByteArray {
        val file = raf ?: throw IOException("cache non ouvert")
        val size = layout.sealedSizeOf(index)
        val offset = layout.sealedOffset(index)

        if (index < present.size && present[index.toInt()].toInt() == 1) {
            val bytes = ByteArray(size)
            file.seek(offset)
            file.readFully(bytes)
            return bytes
        }

        val bytes = fetcher.fetch(offset, offset + size - 1)
        requests++
        if (bytes.size != size) {
            throw IOException("bloc $index incomplet : ${bytes.size} au lieu de $size")
        }
        store(index, bytes)
        saveMap()
        return bytes
    }

    /** Le média est-il entièrement sur l'appareil ? */
    fun isComplete(): Boolean = present.isNotEmpty() && present.all { it.toInt() == 1 }

    private fun ensureSized(file: RandomAccessFile) {
        // Le fichier a d'emblée sa taille définitive : chaque bloc est écrit à
        // sa place, et un cache à moitié rempli reste un fichier scellé valide
        // pour les blocs qu'il contient.
        if (file.length() != layout.sealedLength) file.setLength(layout.sealedLength)
    }

    private fun store(index: Long, bytes: ByteArray) {
        val file = raf ?: return
        file.seek(layout.sealedOffset(index))
        file.write(bytes)
        if (index < present.size) present[index.toInt()] = 1
    }

    private fun saveMap() {
        try {
            map.parentFile?.mkdirs()
            map.writeBytes(byteArrayOf(1) + present)
        } catch (_: Exception) {
            // La carte est un confort : la perdre coûte un retéléchargement,
            // jamais une panne.
        }
    }

    override fun close() {
        raf?.close()
        raf = null
    }
}

/** Va chercher un intervalle d'octets. Abstrait pour être testable sans réseau. */
fun interface RangeFetcher {
    /** Les octets `[from, toInclusive]`, éventuellement moins en fin de fichier. */
    fun fetch(from: Long, toInclusive: Long): ByteArray
}

/**
 * L'implémentation réelle : une requête HTTP `Range` sur l'URL signée.
 *
 * ⚠️ **L'URL signée expire** (une heure aujourd'hui). C'est large pour une
 * session de visionnage, mais un lecteur laissé ouvert plus longtemps verra ses
 * requêtes refusées. Le renouvellement en cours de lecture n'est pas
 * implémenté — il demandera un aller-retour vers le Dart.
 */
class HttpRangeFetcher(private val url: String) : RangeFetcher {

    override fun fetch(from: Long, toInclusive: Long): ByteArray {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Range", "bytes=$from-$toInclusive")
            connectTimeout = 15_000
            readTimeout = 15_000
        }
        try {
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_PARTIAL && code != HttpURLConnection.HTTP_OK) {
                throw IOException("intervalle refusé ($code)")
            }
            val bytes = connection.inputStream.use { it.readBytes() }
            // Un serveur qui ignore l'en-tête `Range` renvoie tout le fichier :
            // on rogne, sinon le bloc serait faux et l'authentification GCM
            // échouerait sans qu'on sache pourquoi.
            return if (code == HttpURLConnection.HTTP_OK && from > 0) {
                val end = minOf(bytes.size.toLong(), toInclusive + 1).toInt()
                bytes.copyOfRange(from.toInt(), end)
            } else {
                bytes
            }
        } finally {
            connection.disconnect()
        }
    }
}
