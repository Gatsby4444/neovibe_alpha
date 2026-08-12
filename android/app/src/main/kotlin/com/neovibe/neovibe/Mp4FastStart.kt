package com.neovibe.neovibe

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/**
 * Déplace l'index d'un MP4 (`moov`) **en tête de fichier**.
 *
 * ### Pourquoi
 *
 * `MediaMuxer` et CameraX écrivent l'index **à la fin** : ils ne connaissent la
 * table des images qu'une fois l'enregistrement terminé. C'est sans importance
 * pour un fichier local, et coûteux dès qu'on lit à distance — le lecteur doit
 * d'abord aller chercher la fin du fichier pour savoir décoder le début, soit
 * un aller-retour réseau perdu **sur chaque vidéo**, avant la première image.
 *
 * Cible fixée par Jay le 2026-08-12 : première image en moins de 300 ms sur un
 * contenu préchargé, moins d'une seconde à froid. Un aller-retour mobile en
 * coûte 100 à 200 : ce n'est pas une optimisation de confort.
 *
 * ### Ce que ça fait, exactement
 *
 * Le fichier est réécrit en plaçant `moov` juste avant `mdat`, et les décalages
 * de la table des morceaux (`stco` / `co64`) sont **corrigés de la taille de
 * `moov`** — sans quoi chaque décalage pointerait
 * à côté et la vidéo serait illisible.
 *
 * ### Ce qu'il ne fait pas
 *
 * **Il ne devine pas.** Toute disposition qu'il ne reconnaît pas — pas de
 * `moov`, pas de `mdat`, boîte de taille aberrante — laisse le fichier
 * **intact** et rend [Result.UNSUPPORTED]. Une vidéo qui démarre un peu moins
 * vite vaut infiniment mieux qu'une vidéo corrompue, et le format hérité nous a
 * déjà appris qu'on ne migre pas ce qu'on ne comprend pas.
 */
object Mp4FastStart {

    enum class Result {
        /** `moov` était déjà avant `mdat` : rien à faire. */
        ALREADY_FAST,

        /** Le fichier a été réécrit. */
        MOVED,

        /** Disposition non reconnue : fichier laissé intact. */
        UNSUPPORTED,

        /** Une erreur d'entrée/sortie : fichier laissé intact. */
        FAILED,
    }

    private const val HEADER = 8L
    private const val LARGE_HEADER = 16L

    private data class Box(val offset: Long, val size: Long, val type: String)

    fun apply(file: File): Result {
        val target = File("${file.path}.faststart")
        val outcome = try {
            RandomAccessFile(file, "r").use { raf -> rewrite(raf, target) }
        } catch (_: Exception) {
            Result.FAILED
        }
        // Le fichier source est refermé AVANT tout renommage : sous Windows,
        // remplacer un fichier encore ouvert échoue en silence, et sur un
        // téléphone ça laisserait un descripteur sur une vidéo qui n'existe
        // plus.
        if (outcome != Result.MOVED) {
            target.delete()
            return outcome
        }
        return swap(file, target)
    }

    /** Écrit la version réordonnée dans [target]. Ne touche pas au fichier source. */
    private fun rewrite(raf: RandomAccessFile, target: File): Result {
        val boxes = topLevelBoxes(raf) ?: return Result.UNSUPPORTED
        val moovIndex = boxes.indexOfFirst { it.type == "moov" }
        val mdatIndex = boxes.indexOfFirst { it.type == "mdat" }
        if (moovIndex < 0 || mdatIndex < 0) return Result.UNSUPPORTED
        if (moovIndex < mdatIndex) return Result.ALREADY_FAST

        val moov = boxes[moovIndex]
        // L'index tient en mémoire (quelques dizaines de kilo-octets pour une
        // minute de vidéo) ; le reste du fichier est recopié en flux.
        val moovBytes = ByteArray(moov.size.toInt())
        raf.seek(moov.offset)
        raf.readFully(moovBytes)

        if (!shiftChunkOffsets(moovBytes, moov.size)) return Result.UNSUPPORTED

        target.outputStream().use { out ->
            val buffer = ByteArray(256 * 1024)
            for (box in boxes) {
                if (box.type == "moov") continue
                // `moov` s'insère juste avant les données : c'est ce qui permet
                // au lecteur de décoder dès les premiers octets reçus.
                if (box.type == "mdat") out.write(moovBytes)
                raf.seek(box.offset)
                var left = box.size
                while (left > 0) {
                    val read = raf.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                    if (read <= 0) throw java.io.IOException("fichier tronqué")
                    out.write(buffer, 0, read)
                    left -= read
                }
            }
        }
        return Result.MOVED
    }

    /**
     * Remplace [file] par [target], en gardant l'original de côté jusqu'au
     * dernier moment : à aucun instant la vidéo ne doit pouvoir disparaître
     * parce qu'un renommage a échoué.
     */
    private fun swap(file: File, target: File): Result {
        val backup = File("${file.path}.bak")
        backup.delete()
        if (!file.renameTo(backup)) {
            target.delete()
            return Result.FAILED
        }
        if (!target.renameTo(file)) {
            backup.renameTo(file) // on remet l'original en place
            target.delete()
            return Result.FAILED
        }
        backup.delete()
        return Result.MOVED
    }

    /** Les boîtes de premier niveau, ou nul si la structure n'est pas cohérente. */
    private fun topLevelBoxes(raf: RandomAccessFile): List<Box>? {
        val boxes = mutableListOf<Box>()
        val length = raf.length()
        var offset = 0L
        val header = ByteArray(16)

        while (offset < length) {
            if (length - offset < HEADER) return null
            raf.seek(offset)
            raf.readFully(header, 0, 8)
            val buffer = ByteBuffer.wrap(header)
            var size = (buffer.int.toLong() and 0xFFFFFFFFL)
            val type = String(header, 4, 4, Charsets.US_ASCII)

            when (size) {
                1L -> {
                    // Taille sur 64 bits : les vidéos de plus de 4 Go la
                    // demandent. On ne l'a jamais vue ici, mais la lire coûte
                    // huit octets et l'ignorer casserait le fichier.
                    if (length - offset < LARGE_HEADER) return null
                    raf.readFully(header, 8, 8)
                    size = ByteBuffer.wrap(header, 8, 8).long
                }
                // Taille 0 = « jusqu'à la fin du fichier », légal pour la
                // dernière boîte seulement.
                0L -> size = length - offset
            }
            if (size < HEADER || offset + size > length) return null

            boxes.add(Box(offset, size, type))
            offset += size
        }
        return boxes.takeIf { it.isNotEmpty() }
    }

    /**
     * Ajoute [delta] à tous les décalages de `stco` / `co64` contenus dans
     * [moov]. Rend faux si la structure n'est pas celle attendue.
     *
     * Ces tables disent où chaque morceau d'image commence **dans le fichier**,
     * en absolu. Déplacer `moov` avant `mdat` décale tout ce qui suit d'exactement
     * sa taille — c'est pourquoi la correction est la même pour tous.
     */
    private fun shiftChunkOffsets(moov: ByteArray, delta: Long): Boolean {
        var patched = false
        // Seuls les conteneurs menant à `stbl` sont ouverts : descendre à
        // l'aveugle risquerait de prendre des données d'échantillon pour des
        // boîtes.
        val containers = setOf("moov", "trak", "mdia", "minf", "stbl", "edts")

        fun walk(from: Int, to: Int): Boolean {
            var offset = from
            while (offset + 8 <= to) {
                val size = ByteBuffer.wrap(moov, offset, 4).int.toLong() and 0xFFFFFFFFL
                val type = String(moov, offset + 4, 4, Charsets.US_ASCII)
                if (size < 8 || offset + size > to) return false
                val end = (offset + size).toInt()

                when {
                    type in containers -> if (!walk(offset + 8, end)) return false
                    type == "stco" || type == "co64" -> {
                        // version(1) + flags(3) + nombre d'entrées(4)
                        var cursor = offset + 12
                        if (cursor + 4 > end) return false
                        val count = ByteBuffer.wrap(moov, cursor, 4).int
                        cursor += 4
                        val width = if (type == "stco") 4 else 8
                        if (count < 0 || cursor + count.toLong() * width > end) return false
                        repeat(count) {
                            if (width == 4) {
                                val value = (ByteBuffer.wrap(moov, cursor, 4).int.toLong()
                                    and 0xFFFFFFFFL) + delta
                                // Un décalage 32 bits qui déborde rendrait la
                                // vidéo illisible en silence : on refuse plutôt
                                // que de tronquer.
                                if (value > 0xFFFFFFFFL) return false
                                ByteBuffer.wrap(moov, cursor, 4).putInt(value.toInt())
                            } else {
                                val value = ByteBuffer.wrap(moov, cursor, 8).long + delta
                                ByteBuffer.wrap(moov, cursor, 8).putLong(value)
                            }
                            cursor += width
                        }
                        patched = true
                    }
                }
                offset = end
            }
            return true
        }

        // Le contenu de `moov` commence après son propre en-tête.
        return walk(8, moov.size) && patched
    }
}
