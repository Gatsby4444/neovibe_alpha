package com.neovibe.neovibe

import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * **Scelle** un fichier au format `NVC1` — le miroir de [SealedChunkReader],
 * et l'équivalent natif de `ChunkedSeal.sealFile` (Dart).
 *
 * ### Pourquoi (2026-09-19)
 *
 * Le scellage se faisait en Dart, **sur le fil de l'interface**, à ~2,7 Mo/s
 * sur le téléphone de Jay : une vidéo de 25 Mo, c'était ~9 s d'écran figé
 * avant l'envoi — pour chaque vidéo d'une publication. Ici, `javax.crypto`
 * passe par les instructions AES du processeur, sur le fil de travail, et
 * la mémoire reste bornée à un bloc.
 *
 * ### Le format, à l'octet près (`docs/format-media-scelle.md`)
 *
 * - en-tête 16 octets, big-endian : magie `NVC1`, taille de bloc (u32),
 *   longueur du clair (u64) ;
 * - puis, par bloc de clair : nonce (12 octets, aléatoire) · chiffré ·
 *   MAC (16 octets). AES-256-GCM, sans données associées — exactement ce que
 *   `SecretBox.concatenation()` écrit côté Dart.
 *
 * ⚠️ Ne rien changer ici sans passer par la spécification : un fichier
 * scellé ici doit se lire en Dart ET en Kotlin, et réciproquement.
 */
object SealedChunkWriter {
    const val CHUNK_SIZE = 256 * 1024
    private const val NONCE_SIZE = 12
    private const val MAC_BITS = 128
    private const val MAGIC = 0x4E564331 // 'NVC1'

    private val random = SecureRandom()

    /**
     * Scelle [source] dans [target] avec la clé [keyBase64]. Écrit d'abord
     * un `.part`, renommé à la fin : un fichier partiel ne doit jamais
     * passer pour un scellé valide.
     */
    fun seal(source: File, target: File, keyBase64: String) {
        val key = SecretKeySpec(Base64.getDecoder().decode(keyBase64), "AES")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val plainLength = source.length()
        val tmp = File(target.path + ".part")
        target.parentFile?.mkdirs()
        RandomAccessFile(source, "r").use { input ->
            DataOutputStream(FileOutputStream(tmp).buffered(1 shl 20)).use { out ->
                out.writeInt(MAGIC)
                out.writeInt(CHUNK_SIZE)
                out.writeLong(plainLength)
                val clear = ByteArray(CHUNK_SIZE)
                val nonce = ByteArray(NONCE_SIZE)
                var remaining = plainLength
                while (remaining > 0) {
                    val take = minOf(remaining, CHUNK_SIZE.toLong()).toInt()
                    input.readFully(clear, 0, take)
                    random.nextBytes(nonce)
                    cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(MAC_BITS, nonce))
                    val sealed = cipher.doFinal(clear, 0, take)
                    out.write(nonce)
                    out.write(sealed)
                    remaining -= take
                }
            }
        }
        MediaTranscoder.moveInto(tmp, target)?.let { throw IllegalStateException(it) }
    }
}
