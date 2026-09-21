package com.neovibe.neovibe.publish

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.Executors
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **La file de publication, sans codec ni réseau** : ce qui compte est
 * l'ordre des pas, ce qui est réécrit sur le disque, et ce qu'un pas
 * interrompu coûte quand on le reprend.
 */
class PublishPipelineTest {
    private val root = Files.createTempDirectory("publish").toFile()
    private val store = PublishStore(root)
    private val session = Session("https://x", "anon", "jwt")
    private val exec = Executors.newSingleThreadExecutor()

    @After
    fun tearDown() {
        exec.shutdownNow()
        root.deleteRecursively()
    }

    /** Un faux serveur : accepte tout, garde les octets par chemin, peut casser. */
    private class FakeRemote : Remote {
        val objects = HashMap<String, Long>() // chemin → octets reçus
        val urls = HashMap<String, String>() // url → chemin
        var creates = 0
        var patches = 0
        var rpcBodies = mutableListOf<String>()
        var deleted = mutableListOf<String>()
        /** Casse (réseau) après ce nombre de blocs acceptés ; -1 = jamais. */
        var breakAfterPatches = -1
        var authFails = false
        var rejectRpc: String? = null

        override fun tusCreate(bucket: String, path: String, size: Long, contentType: String): String {
            if (authFails) throw AuthExpired("jeton")
            creates++
            val url = "https://x/up/${urls.size}"
            urls[url] = path
            objects[path] = 0
            return url
        }

        override fun tusOffset(uploadUrl: String): Long? = urls[uploadUrl]?.let { objects[it] }

        override fun tusPatch(
            uploadUrl: String,
            file: File,
            offset: Long,
            onOffset: (Long) -> Unit,
            isCancelled: () -> Boolean,
        ): Long {
            val path = urls[uploadUrl] ?: throw IOException("session inconnue")
            assertEquals("on repart de ce que le serveur a", objects[path], offset)
            var at = offset
            val total = file.length()
            while (at < total) {
                if (breakAfterPatches == 0) throw IOException("réseau coupé")
                if (breakAfterPatches > 0) breakAfterPatches--
                at = minOf(at + CHUNK, total)
                objects[path] = at
                patches++
                onOffset(at)
            }
            return at
        }

        override fun deleteObject(bucket: String, path: String) {
            deleted.add(path)
        }

        override fun rpc(name: String, jsonBody: String) {
            if (authFails) throw AuthExpired("jeton")
            rejectRpc?.let { throw Rejected(it) }
            rpcBodies.add(jsonBody)
        }

        companion object {
            const val CHUNK = 1000L
        }
    }

    /**
     * De faux outils : « transcoder » copie, « fast-start » note le fichier,
     * « sceller » copie en ajoutant un en-tête.
     */
    private val tools = object : MediaTools {
        var transcodes = 0
        val fastStarted = mutableListOf<String>()
        override fun transcode(
            spec: TranscodeSpec,
            source: File,
            dest: File,
            onProgress: (Float) -> Unit,
            isCancelled: () -> Boolean,
        ): Int {
            transcodes++
            source.copyTo(dest, overwrite = true)
            onProgress(1f)
            return 4321
        }

        override fun poster(source: File, dest: File, width: Int, atMs: Int): String? {
            dest.writeBytes(ByteArray(100) { 7 })
            return null
        }

        override fun fastStart(file: File) {
            fastStarted.add(file.name)
        }

        override fun seal(source: File, dest: File, keyBase64: String) {
            dest.writeBytes("SEAL".toByteArray() + source.readBytes())
        }
    }

    private fun pipeline(remote: Remote, changes: MutableList<String> = mutableListOf()) = PublishPipeline(
        store = store,
        session = { session },
        remote = { remote },
        tools = tools,
        uploads = exec,
        onChange = { changes.add("${it.phase}@${it.progress}") },
    )

    private fun job(id: String = "item-1", video: Boolean = false): PublishJob {
        val dir = store.dir(id)
        val cache = File(root, "own")
        val photo = File(dir, "p0.jpg").apply { writeBytes(ByteArray(2500) { 1 }) }
        val media = mutableListOf(
            PublishMedia(
                slot = 0, isVideo = false, width = 1080, height = 1350,
                file = PublishFile(0, photo.path, "${photo.path}.seal", "me/${id}_0.jpg"),
            ),
        )
        if (video) {
            val src = File(dir, "v1_src.mp4").apply { writeBytes(ByteArray(7000) { 2 }) }
            val overlay = File(dir, "v1_overlay.png").apply { writeBytes(ByteArray(10)) }
            val out = File(dir, "v1.mp4")
            val poster = File(dir, "v1_poster.jpg")
            media.add(
                PublishMedia(
                    slot = 1, isVideo = true, width = 1080, height = 1350,
                    source = src.path,
                    transcode = TranscodeSpec(0, 5000, List(8) { 0f }, 1080, 1350, List(24) { 0f }, overlay.path, 0),
                    coverMs = 1500, maxDurationMs = 60000,
                    file = PublishFile(1, out.path, "${out.path}.seal", "me/${id}_1.mp4"),
                    poster = PublishFile(101, poster.path, "${poster.path}.seal", "me/${id}_1_poster.jpg"),
                ),
            )
        }
        return PublishJob(
            id = id, ownerId = "me", createdAt = 1L, cardType = "oneshot", mediaKey = "key", media = media,
            ownCache = mapOf("0" to File(cache, "${id}_front.seal").path, "1" to File(cache, "${id}_back.seal").path, "101" to File(cache, "${id}_slot101.seal").path),
            cover = File(dir, "cover.jpg").apply { writeBytes(ByteArray(5)) }.path,
        ).also { store.save(it) }
    }

    @Test
    fun `une photo - preparee et deposee avant Publier, inscrite apres`() {
        val remote = FakeRemote()
        val p = pipeline(remote)
        val j = job()

        assertTrue("sans « Publier », on attend", p.process(j) is Wait.Release)
        assertEquals(PublishJob.WAITING, store.load(j.id)!!.phase)
        assertEquals("un envoi ouvert", 1, remote.creates)
        assertEquals("tout est déjà au coffre", 2504L, remote.objects["me/item-1_0.jpg"])
        assertFalse("le clair est effacé une fois scellé", File(j.media[0].file.clear).exists())
        assertTrue("rien d'inscrit avant « Publier »", remote.rpcBodies.isEmpty())

        store.saveRelease(j.id, Release(caption = "coucou", isPublic = true))
        assertTrue(p.process(store.load(j.id)!!) is Wait.None)
        val done = store.load(j.id)!!
        assertEquals(PublishJob.DONE, done.phase)
        assertEquals(1, remote.rpcBodies.size)
        val body = remote.rpcBodies[0]
        assertTrue(body, body.contains("\"p_caption\":\"coucou\""))
        assertTrue(body, body.contains("\"p_is_public\":true"))
        assertTrue(body, body.contains("\"p_kind\":\"card\""))
        assertTrue("le type de la Vibe part tel quel", body.contains("\"p_card_type\":\"oneshot\""))
        assertTrue(body, body.contains("\"path\":\"me/item-1_0.jpg\""))
        assertTrue("le scellé est dans le cache de mes contenus", File(j.ownCache["0"]!!).exists())
        assertEquals("SEAL", File(j.ownCache["0"]!!).readBytes().copyOfRange(0, 4).decodeToString())
        assertFalse("le scellé de travail est parti", File(j.media[0].file.sealed).exists())
        assertTrue("la couverture reste pour l'app", File(j.cover!!).exists())
        assertTrue("job.json reste jusqu'à l'acquittement", File(store.dir(j.id), "job.json").exists())
    }

    @Test
    fun `une video - transcodee une fois, couverte, scellee, la source et le calque s'effacent`() {
        val remote = FakeRemote()
        val p = pipeline(remote)
        val j = job(video = true)
        store.saveRelease(j.id, Release())
        assertTrue(p.process(j) is Wait.None)
        val done = store.load(j.id)!!
        assertEquals(PublishJob.DONE, done.phase)
        assertEquals(1, tools.transcodes)
        assertEquals(4321, done.media[1].durationMs)
        assertFalse(File(j.media[1].source!!).exists())
        assertFalse(File(j.media[1].transcode!!.overlayPath!!).exists())
        assertEquals("trois fichiers déposés : photo, vidéo, couverture", 3, remote.creates)
        assertEquals("l'index remis en tête sur la vidéo produite, et sur elle seule", listOf("v1.mp4"), tools.fastStarted)
        val body = remote.rpcBodies[0]
        assertTrue(body, body.contains("\"duration_ms\":4321"))
        assertTrue(body, body.contains("\"poster_path\":\"me/item-1_1_poster.jpg\""))
        assertTrue(File(j.ownCache["101"]!!).exists())
    }

    @Test
    fun `une Vibe video - face finale, pas de transcodage, index en tete avant le scellage`() {
        // Ce que le Dart dépose depuis le 2026-09-21 : une face vidéo déjà
        // rendue (caméra ou éditeur), sans source ni paramètres, sans couverture.
        val id = "vibe-1"
        val dir = store.dir(id)
        val face = File(dir, "face_0.mp4").apply { writeBytes(ByteArray(3000) { 3 }) }
        val j = PublishJob(
            id = id, ownerId = "me", createdAt = 1L, cardType = "standard", mediaKey = "key",
            media = listOf(
                PublishMedia(
                    slot = 0, isVideo = true,
                    file = PublishFile(0, face.path, "${face.path}.seal", "me/${id}_0.mp4"),
                ),
            ),
            ownCache = mapOf("0" to File(root, "own/${id}_0.seal").path),
        ).also { store.save(it) }
        store.saveRelease(id, Release(isPublic = true))
        val remote = FakeRemote()
        assertTrue(pipeline(remote).process(j) is Wait.None)
        val done = store.load(id)!!
        assertEquals(PublishJob.DONE, done.phase)
        assertEquals("rien à transcoder", 0, tools.transcodes)
        assertEquals("l'index en tête, sur la face, avant le scellage", listOf("face_0.mp4"), tools.fastStarted)
        assertNull("pas de durée : la capture ne la mesure pas", done.media[0].durationMs)
        assertEquals("un seul fichier déposé : pas de couverture", 1, remote.creates)
        val body = remote.rpcBodies[0]
        assertTrue(body, body.contains("\"p_kind\":\"card\""))
        assertTrue(body, body.contains("\"duration_ms\":null"))
        assertTrue(body, body.contains("\"poster_path\":null"))
        assertTrue(body, body.contains("\"width\":null"))
        assertTrue(File(j.ownCache["0"]!!).exists())
    }

    @Test
    fun `reseau coupe en plein envoi - on reprend a l'offset du serveur, sans rien renvoyer`() {
        val remote = FakeRemote().apply { breakAfterPatches = 1 }
        val p = pipeline(remote)
        val j = job()
        store.saveRelease(j.id, Release())

        val w = p.process(j)
        assertTrue("$w", w is Wait.Backoff)
        assertEquals(5_000L, (w as Wait.Backoff).delayMs)
        val saved = store.load(j.id)!!
        assertEquals(PublishJob.UPLOADING, saved.phase)
        assertNotNull("l'URL de reprise est sur le disque", saved.files[0].uploadUrl)
        assertEquals(1000L, remote.objects["me/item-1_0.jpg"])
        assertEquals(1, remote.patches)

        // La reprise : un nouveau pipeline (le processus a pu mourir), qui relit le disque.
        remote.breakAfterPatches = -1
        assertTrue(pipeline(remote).process(store.load(j.id)!!) is Wait.None)
        assertEquals("pas de nouvelle session d'envoi", 1, remote.creates)
        assertEquals("les 1 504 octets restants, en deux blocs — pas les 2 504", 3, remote.patches)
        assertEquals(PublishJob.DONE, store.load(j.id)!!.phase)
    }

    @Test
    fun `attente croissante - 5 s, 10 s, 20 s, plafond 5 min`() {
        assertEquals(5_000L, PublishPipeline.backoff(1))
        assertEquals(10_000L, PublishPipeline.backoff(2))
        assertEquals(20_000L, PublishPipeline.backoff(3))
        assertEquals(300_000L, PublishPipeline.backoff(7))
        assertEquals(300_000L, PublishPipeline.backoff(40))
    }

    @Test
    fun `jeton refuse - on attend l'app, la publication ne bouge pas`() {
        val remote = FakeRemote().apply { authFails = true }
        val j = job()
        assertTrue(pipeline(remote).process(j) is Wait.Token)
        val saved = store.load(j.id)!!
        assertEquals(PublishJob.UPLOADING, saved.phase)
        assertNull(saved.error)
        assertTrue("le scellage, lui, est fait", saved.files[0].isSealed)
        remote.authFails = false
        assertTrue(pipeline(remote).process(store.load(j.id)!!) is Wait.Release)
    }

    @Test
    fun `refus du serveur - echec, avec son message, et rien ne se reessaie seul`() {
        val remote = FakeRemote().apply { rejectRpc = "Une publication contient de 1 à 20 médias" }
        val j = job()
        store.saveRelease(j.id, Release())
        assertTrue(pipeline(remote).process(j) is Wait.None)
        val saved = store.load(j.id)!!
        assertEquals(PublishJob.FAILED, saved.phase)
        assertEquals("Une publication contient de 1 à 20 médias", saved.error)
        assertTrue("les envois faits restent faits", saved.files.all { it.uploaded })
    }

    @Test
    fun `annulation - ce qui est au coffre s'efface, le dossier aussi`() {
        val remote = FakeRemote()
        val j = job()
        assertTrue(pipeline(remote).process(j) is Wait.Release)
        store.markCancelled(j.id)
        assertTrue(pipeline(remote).process(store.load(j.id)!!) is Wait.None)
        assertEquals(listOf("me/item-1_0.jpg"), remote.deleted)
        assertNull("plus rien sur le disque", store.load(j.id))
        assertFalse(File(root, "publish/${j.id}").exists())
    }

    @Test
    fun `le fichier de travail se relit tel quel`() {
        val j = job(video = true)
        val back = PublishJob.fromJson(j.toJson())
        assertEquals(j, back)
        assertEquals(j.files.map { it.storagePath }, back.files.map { it.storagePath })
    }
}
