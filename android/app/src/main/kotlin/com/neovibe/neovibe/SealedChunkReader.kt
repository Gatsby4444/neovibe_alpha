package com.neovibe.neovibe

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Accès **aléatoire** au clair d'un média scellé au format `NVC1`.
 *
 * C'est la moitié Kotlin du format — la moitié Dart est [ChunkedSeal]
 * (`lib/core/crypto/chunked_seal.dart`). La spécification qui les lie, et les
 * vecteurs de test croisés qui les empêchent de diverger, sont dans
 * `docs/format-media-scelle.md`. **Ne rien changer ici sans y passer.**
 *
 * ### Pourquoi ce code existe
 *
 * Le déchiffrement en Dart pur plafonne à ~2,7 Mo/s et s'exécutait sur
 * l'isolate qui dessine l'écran : c'est la cause mesurée du saccadement de la
 * v0.9.55. Ici, `javax.crypto` passe par les instructions AES du processeur, et
 * le travail se fait sur les fils du lecteur — jamais sur celui de l'interface.
 *
 * ### Ce qu'il ne fait pas
 *
 * Il ne **scelle** rien : sceller reste en Dart, une fois, à l'envoi. Et il
 * n'implémente **pas** le format hérité (bloc unique, antérieur au
 * 2026-08-12), qui garde son chemin Dart et s'éteindra de lui-même.
 *
 * Cette classe n'est **pas** sûre en accès concurrent : un lecteur par source
 * de données, une source de données par lecteur.
 */
class SealedChunkReader(
    private val store: SealedChunkStore,
    keyBase64: String,
) : Closeable {

    /** Le cas d'un média entièrement présent sur l'appareil. */
    constructor(file: File, keyBase64: String) : this(LocalChunkStore(file), keyBase64)

    companion object {
        const val HEADER_SIZE = 16
        private const val NONCE_SIZE = 12
        private const val MAC_SIZE = 16

        /** AES-GCM ajoute exactement 28 octets par bloc : nonce + MAC. */
        const val OVERHEAD = NONCE_SIZE + MAC_SIZE

        private const val MAGIC = 0x4E564331 // 'NVC1'

        /**
         * Le fichier porte-t-il la magie du format par blocs ?
         *
         * Son absence n'est pas une erreur : c'est un média scellé avant le
         * 2026-08-12, qui suit un autre chemin.
         */
        fun isSealed(file: File): Boolean = try {
            RandomAccessFile(file, "r").use {
                it.length() >= HEADER_SIZE && it.readInt() == MAGIC
            }
        } catch (_: Exception) {
            false
        }
    }

    private val key = SecretKeySpec(Base64.getDecoder().decode(keyBase64), "AES")
    private val cipher: Cipher = Cipher.getInstance("AES/GCM/NoPadding")

    /** Taille du clair d'un bloc plein. **Lue dans l'en-tête**, jamais supposée. */
    private val chunkSize: Int

    /** Longueur du clair d'origine — ce que le lecteur vidéo doit connaître d'avance. */
    val plainLength: Long

    /**
     * Le dernier bloc déchiffré, gardé tel quel. Une lecture séquentielle
     * traverse un bloc en plusieurs appels : sans ce cache, chaque appel
     * redéchiffrerait 256 Ko — et, sur une source distante, pourrait le
     * redemander au réseau.
     */
    private var cachedIndex = -1L
    private var cached: ByteArray? = null

    init {
        try {
            store.open()
        } catch (e: Exception) {
            store.close()
            throw e
        }
        chunkSize = store.layout.chunkSize
        plainLength = store.layout.plainLength
    }

    /**
     * Lit au plus [length] octets de clair à partir de [position].
     *
     * Rend le nombre d'octets écrits, `-1` à la fin du média. Un appel ne
     * traverse **jamais** plus d'un bloc : c'est ce qui borne la mémoire à un
     * bloc, quelle que soit la taille de la vidéo. L'appelant boucle.
     */
    fun read(position: Long, out: ByteArray, offset: Int, length: Int): Int {
        if (position < 0) throw IOException("position négative : $position")
        if (position >= plainLength || length <= 0) return -1

        val index = position / chunkSize
        val chunk = chunkAt(index)
        val within = (position - index * chunkSize).toInt()
        val count = minOf(length, chunk.size - within)
        System.arraycopy(chunk, within, out, offset, count)
        return count
    }

    /** Le bloc [index], déchiffré. La position se **calcule** — aucune table d'index. */
    private fun chunkAt(index: Long): ByteArray {
        cached?.let { if (cachedIndex == index) return it }

        val plainInChunk = store.layout.sealedSizeOf(index) - OVERHEAD
        val sealed = store.sealedChunk(index)

        // GCM n'authentifie qu'un message ENTIER : le bloc est déchiffré en
        // totalité, puis rogné par l'appelant. Un MAC invalide lève ici — on
        // ne rend jamais d'octets non authentifiés.
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(MAC_SIZE * 8, sealed, 0, NONCE_SIZE),
        )
        val clear = cipher.doFinal(sealed, NONCE_SIZE, plainInChunk + MAC_SIZE)

        cachedIndex = index
        cached = clear
        return clear
    }

    override fun close() {
        cached = null
        cachedIndex = -1
        store.close()
    }
}
