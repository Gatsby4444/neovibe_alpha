package com.neovibe.neovibe.publish

import android.content.Context
import java.io.File

/**
 * **Le rangement des publications en cours** : un dossier par publication
 * sous `<filesDir>/publish/<id>/`, avec `job.json` et tous ses fichiers de
 * travail (rendus, transcodés, scellés, couverture).
 *
 * ⚠️ **Pas sous `work/`** (`WorkDir` côté Dart) : ce dossier-là est balayé à
 * chaque démarrage de l'app — « rien n'est en vol à ce moment-là » — ce qui
 * n'est plus vrai d'une publication que le service finit sans l'app. Deux
 * durées de vie, deux dossiers (règle 2 de `CLAUDE.md`).
 *
 * `job.json` s'écrit en deux temps (`.tmp` puis renommage) : un fichier à
 * moitié écrit au moment où le processus meurt serait illisible, et la
 * publication perdue avec lui.
 */
class PublishStore(private val root: File) {

    constructor(context: Context) : this(File(context.filesDir, "publish"))

    /** Le dossier de travail d'une publication, créé s'il manque. */
    fun dir(id: String): File = File(root, id).also { it.mkdirs() }

    // Les lectures ne créent rien : un dossier effacé doit le rester.
    private fun jobFile(id: String) = File(File(root, id), "job.json")

    fun load(id: String): PublishJob? = runCatching {
        val f = jobFile(id)
        if (!f.exists()) null else PublishJob.fromJson(f.readText())
    }.getOrNull()

    @Synchronized
    fun save(job: PublishJob) {
        val f = jobFile(job.id)
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeText(job.toJson())
        if (!tmp.renameTo(f)) {
            f.delete()
            tmp.renameTo(f)
        }
    }

    /** Toutes les publications rangées, les plus anciennes d'abord. */
    fun all(): List<PublishJob> =
        (root.listFiles() ?: emptyArray())
            .filter { it.isDirectory }
            .mapNotNull { load(it.name) }
            .sortedBy { it.createdAt }

    fun active(): List<PublishJob> = all().filter { it.isActive }

    // Ce que l'app dépose, dans ses propres fichiers (voir [PublishJob]).

    private fun releaseFile(id: String) = File(File(root, id), "release.json")

    fun release(id: String): Release? = runCatching {
        val f = releaseFile(id)
        if (!f.exists()) null else Release.fromJson(f.readText())
    }.getOrNull()

    fun saveRelease(id: String, release: Release) {
        val f = releaseFile(id)
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeText(release.toJson())
        if (!tmp.renameTo(f)) {
            f.delete()
            tmp.renameTo(f)
        }
    }

    /** L'annulation, sur le disque : elle survit au processus, le pipeline la relit. */
    fun markCancelled(id: String) {
        File(dir(id), "cancel").writeText("")
    }

    fun isCancelled(id: String): Boolean = File(File(root, id), "cancel").exists()

    /** Efface la publication et tout son dossier de travail. */
    fun delete(id: String) {
        File(root, id).deleteRecursively()
    }
}
