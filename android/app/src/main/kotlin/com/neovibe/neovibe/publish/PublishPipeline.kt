package com.neovibe.neovibe.publish

import com.google.gson.GsonBuilder
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Future

/**
 * Ce que la file demande à la machine : transcoder, extraire une couverture,
 * sceller. Une interface, pour éprouver [PublishPipeline] sans codec ni GPU.
 */
interface MediaTools {
    /** Rend la durée du fichier produit, ou lève avec le message du transcodeur. */
    fun transcode(
        spec: TranscodeSpec,
        source: File,
        dest: File,
        onProgress: (Float) -> Unit,
        isCancelled: () -> Boolean,
    ): Int

    /** Écrit la couverture ; rend null si tout va bien, sinon le message. */
    fun poster(source: File, dest: File, width: Int, atMs: Int): String?

    fun seal(source: File, dest: File, keyBase64: String)
}

/** Pourquoi le pipeline s'est arrêté sur cette publication. */
sealed class Wait {
    /** Rien à attendre : finie, échouée ou annulée. */
    object None : Wait()

    /** Tout est prêt et déposé ; il manque « Publier ». */
    object Release : Wait()

    /** Le jeton est refusé : l'app doit en déposer un frais. */
    object Token : Wait()

    /** Le réseau a lâché : réessayer dans [delayMs]. */
    class Backoff(val delayMs: Long) : Wait()
}

/**
 * **Le travail d'une publication, étape par étape, reprenable à chaque pas.**
 *
 * Chaque étape relit l'état sur le disque, fait ce qui manque, l'écrit. Si
 * le processus meurt, la prochaine passe repart de là — une vidéo déjà
 * transcodée ne l'est pas deux fois, un envoi repart de l'offset que le
 * serveur a. C'est ce qui rend « survit à la fermeture de l'app » vrai sans
 * cas particulier.
 *
 * ## Les trois sortes d'erreurs, trois suites différentes
 *
 * | erreur | suite |
 * |---|---|
 * | [AuthExpired] | la publication attend un jeton de l'app ([Wait.Token]) |
 * | [Rejected], ou un transcodage / scellage raté | **échec** : l'utilisateur choisit |
 * | toute autre `IOException` (réseau) | attente croissante puis nouvel essai ([Wait.Backoff]) |
 *
 * Un échec de transcodage n'est pas réessayé seul : c'est le même fichier,
 * le même décodeur, il échouerait pareil — et il coûte des secondes de
 * processeur à chaque fois.
 */
class PublishPipeline(
    private val store: PublishStore,
    private val session: () -> Session?,
    private val remote: (Session) -> Remote,
    private val tools: MediaTools,
    private val uploads: ExecutorService,
    /** Un état a changé : à republier vers l'app. */
    private val onChange: (PublishJob) -> Unit,
) {
    private val gson = GsonBuilder().serializeNulls().create()

    /** Relu entre deux pas : l'utilisateur a annulé cette publication. */
    private fun isCancelled(id: String) = store.isCancelled(id)

    /** Fait avancer [job] aussi loin que possible, et dit pourquoi ça s'arrête. */
    fun process(job: PublishJob): Wait {
        return try {
            step(job)
        } catch (e: AuthExpired) {
            job.error = null
            save(job)
            Wait.Token
        } catch (e: Rejected) {
            fail(job, e.message ?: "refusé")
            Wait.None
        } catch (e: IOException) {
            if (isCancelled(job.id)) {
                cancel(job)
                return Wait.None
            }
            job.attempts += 1
            job.error = e.message
            save(job)
            Wait.Backoff(backoff(job.attempts))
        } catch (e: Exception) {
            // Un transcodage interrompu par l'annulation lève « annulé » :
            // ce n'est pas un échec, c'est ce qu'on a demandé.
            if (isCancelled(job.id)) {
                cancel(job)
                return Wait.None
            }
            fail(job, e.message ?: e.javaClass.simpleName)
            Wait.None
        }
    }

    private fun step(job: PublishJob): Wait {
        if (isCancelled(job.id)) {
            cancel(job)
            return Wait.None
        }
        when (job.phase) {
            PublishJob.PREPARING -> {
                prepare(job)
                if (isCancelled(job.id)) {
                    cancel(job)
                    return Wait.None
                }
                job.phase = PublishJob.UPLOADING
                job.progress = 0f
                save(job)
                return step(job)
            }
            PublishJob.UPLOADING -> {
                upload(job)
                if (isCancelled(job.id)) {
                    cancel(job)
                    return Wait.None
                }
                job.phase = if (store.release(job.id) != null) PublishJob.REGISTERING else PublishJob.WAITING
                job.attempts = 0
                save(job)
                return step(job)
            }
            PublishJob.WAITING -> {
                if (store.release(job.id) == null) return Wait.Release
                job.phase = PublishJob.REGISTERING
                save(job)
                return step(job)
            }
            PublishJob.REGISTERING -> {
                register(job)
                finish(job)
                return Wait.None
            }
            else -> return Wait.None
        }
    }

    // ------------------------------------------------------------------
    // Préparation : transcoder, couvrir, sceller
    // ------------------------------------------------------------------

    private fun prepare(job: PublishJob) {
        val n = job.media.size
        job.media.forEachIndexed { i, m ->
            if (isCancelled(job.id)) return
            if (m.isVideo && !m.transcoded) {
                val spec = m.transcode ?: throw IllegalStateException("vidéo sans paramètres")
                val source = File(m.source ?: throw IllegalStateException("vidéo sans source"))
                val duration = tools.transcode(
                    spec,
                    source,
                    File(m.file.clear),
                    onProgress = { p ->
                        job.progress = (i + p) / n
                        onChange(job)
                    },
                    isCancelled = { isCancelled(job.id) },
                )
                if (isCancelled(job.id)) return
                val poster = m.poster ?: throw IllegalStateException("vidéo sans couverture")
                val at = (m.coverMs).coerceIn(0, duration)
                tools.poster(File(m.file.clear), File(poster.clear), m.width, at)
                    ?.let { throw IllegalStateException("couverture : $it") }
                m.durationMs = minOf(duration, m.maxDurationMs.takeIf { it > 0 } ?: duration)
                // La source (copie de la galerie) et le calque ne servent plus.
                source.delete()
                spec.overlayPath?.let { File(it).delete() }
                save(job)
            }
            for (f in listOfNotNull(m.file, m.poster)) {
                if (f.isSealed) continue
                tools.seal(File(f.clear), File(f.sealed), job.mediaKey)
                f.isSealed = true
                File(f.clear).delete()
                save(job)
            }
            job.progress = (i + 1f) / n
            onChange(job)
        }
    }

    // ------------------------------------------------------------------
    // Envoi : TUS, deux fichiers à la fois
    // ------------------------------------------------------------------

    private fun upload(job: PublishJob) {
        val s = session() ?: throw AuthExpired("pas de session")
        val r = remote(s)
        val files = job.files.filter { !it.uploaded }
        if (files.isEmpty()) return
        val sizes = job.files.associate { it.contentSlot to File(it.sealed).length() }
        val total = sizes.values.sum().coerceAtLeast(1L)
        val sent = HashMap<Int, Long>()
        for (f in job.files) if (f.uploaded) sent[f.contentSlot] = sizes[f.contentSlot] ?: 0L
        val lock = Object()
        fun report(f: PublishFile, offset: Long) {
            synchronized(lock) {
                sent[f.contentSlot] = offset
                job.progress = sent.values.sum().toFloat() / total
            }
            onChange(job)
        }

        val futures: List<Future<*>> = files.map { f ->
            uploads.submit {
                val file = File(f.sealed)
                var url = f.uploadUrl
                var offset = url?.let { r.tusOffset(it) }
                if (url == null || offset == null) {
                    url = r.tusCreate(BUCKET, f.storagePath, file.length(), "application/octet-stream")
                    offset = 0L
                    synchronized(lock) { f.uploadUrl = url; save(job) }
                }
                val end = r.tusPatch(url, file, offset, onOffset = { report(f, it) }) { isCancelled(job.id) }
                if (end >= file.length()) {
                    synchronized(lock) {
                        f.uploaded = true
                        save(job)
                    }
                }
            }
        }
        var first: Throwable? = null
        for (fu in futures) {
            try {
                fu.get()
            } catch (e: java.util.concurrent.ExecutionException) {
                if (first == null) first = e.cause ?: e
            }
        }
        first?.let { throw it }
        if (job.files.any { !it.uploaded } && !isCancelled(job.id)) {
            throw IOException("envoi incomplet")
        }
    }

    // ------------------------------------------------------------------
    // Inscription et fin
    // ------------------------------------------------------------------

    private fun register(job: PublishJob) {
        val s = session() ?: throw AuthExpired("pas de session")
        val release = store.release(job.id) ?: throw IllegalStateException("inscription sans « Publier »")
        val rows = job.media.map { m ->
            mapOf(
                "path" to m.file.storagePath,
                "is_video" to m.isVideo,
                "duration_ms" to if (m.isVideo) m.durationMs else null,
                "poster_path" to m.poster?.storagePath,
                "width" to m.width,
                "height" to m.height,
            )
        }
        val body = mapOf(
            "p_item_id" to job.id,
            "p_kind" to job.kind,
            "p_card_type" to "standard",
            "p_media" to rows,
            "p_caption" to release.caption,
            "p_caption_font" to release.captionFont,
            "p_is_public" to release.isPublic,
            "p_shareable" to release.shareable,
            "p_saveable" to release.saveable,
            "p_media_key" to job.mediaKey,
            "p_aspect_w" to job.aspectW,
            "p_aspect_h" to job.aspectH,
            "p_anchor_lat" to release.anchorLat,
            "p_anchor_lng" to release.anchorLng,
        )
        remote(s).rpc("publish_to_library", gson.toJson(body))
    }

    /** Publié : les scellés vont au cache de MES contenus, le reste s'efface. */
    private fun finish(job: PublishJob) {
        for (f in job.files) {
            val dest = job.ownCache[f.contentSlot.toString()] ?: continue
            runCatching {
                val target = File(dest)
                target.parentFile?.mkdirs()
                File(f.sealed).copyTo(target, overwrite = true)
            }
        }
        job.phase = PublishJob.DONE
        job.progress = 1f
        job.error = null
        save(job)
        // Le dossier de travail, sauf `job.json` (l'app l'acquitte) et la couverture.
        val dir = store.dir(job.id)
        dir.listFiles()?.forEach { f ->
            if (f.name != "job.json" && f.path != job.cover) f.delete()
        }
    }

    private fun fail(job: PublishJob, message: String) {
        job.phase = PublishJob.FAILED
        job.error = message
        save(job)
    }

    /** Annulé avant « Publier » : ce qui est déjà au coffre s'efface, au mieux. */
    private fun cancel(job: PublishJob) {
        session()?.let { s ->
            val r = remote(s)
            for (f in job.files) if (f.uploadUrl != null || f.uploaded) r.deleteObject(BUCKET, f.storagePath)
        }
        job.phase = PublishJob.CANCELLED
        save(job)
        store.delete(job.id)
        onChange(job)
    }

    private fun save(job: PublishJob) {
        store.save(job)
        onChange(job)
    }

    companion object {
        const val BUCKET = "library"

        /** 5 s, 10 s, 20 s… plafonné à 5 min. */
        fun backoff(attempts: Int): Long = minOf(5_000L shl (attempts - 1).coerceIn(0, 6), 300_000L)
    }
}
