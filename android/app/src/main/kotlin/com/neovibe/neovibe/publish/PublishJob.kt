package com.neovibe.neovibe.publish

import com.google.gson.Gson
import com.google.gson.GsonBuilder

/**
 * **Une publication en cours**, telle qu'elle est écrite sur le disque.
 *
 * C'est le contrat entre le Dart (qui dépose) et le service natif (qui
 * exécute) — tranché par Jay le 2026-09-19 : *« la publication est une file
 * NATIVE et persistante »*. Tout ce dont le service a besoin pour finir le
 * travail **sans l'app** est ici : les fichiers, les paramètres de
 * transcodage, la clé, les chemins de dépôt, et où chaque étape en est.
 *
 * ## Les phases, dans l'ordre
 *
 * | phase | ce que le service fait |
 * |---|---|
 * | `preparing` | transcode les vidéos, extrait les couvertures, scelle tout |
 * | `uploading` | dépose les scellés (TUS, reprenable, deux à la fois) |
 * | `waiting` | tout est déposé, mais « Publier » n'a pas encore été pressé |
 * | `registering` | l'appel serveur qui crée la publication |
 * | `done` | fini : scellés copiés dans le cache de mes contenus, dossier effacé |
 * | `failed` | une erreur qui ne se réessaie pas seule ; l'utilisateur choisit |
 * | `cancelled` | l'utilisateur est revenu en arrière avant « Publier » |
 *
 * ⚠️ « Publier » est indépendant de la phase : le travail commence à
 * « Suivant », **avant** la légende ; « Publier » ne fait que déposer la
 * [Release] (légende, droits). C'est ce qui rend la publication instantanée
 * du point de vue de l'utilisateur, comme Instagram.
 *
 * ⚠️ **Deux écrivains, deux fichiers.** `job.json` n'est écrit que par le
 * service ; ce que l'app dépose ensuite (« Publier » → `release.json`,
 * annulation → `cancel`) va dans des fichiers à part. Sinon l'app, en posant
 * la légende pendant qu'une vidéo se transcode, écraserait l'état du service
 * — ou l'inverse — en silence.
 *
 * ⚠️ Ce fichier porte la **clé du média** en clair, comme `own_keys.json` côté
 * Dart : c'est le dossier privé de l'app, et la clé de MES contenus y est
 * déjà. Il ne porte **aucun jeton** — la session est un autre fichier, avec
 * une autre durée de vie ([SessionStore]).
 */
data class PublishJob(
    val id: String,
    val ownerId: String,
    val createdAt: Long,
    /** `album` ou `flow` — décidé côté Dart (`kindDuContenu`), vérifié par le serveur. */
    val kind: String,
    val aspectW: Int,
    val aspectH: Int,
    val mediaKey: String,
    val media: List<PublishMedia>,
    /** Où copier chaque scellé une fois publié : place → chemin absolu. */
    val ownCache: Map<String, String> = emptyMap(),
    /** La vignette montrée dans la grille pendant l'envoi. */
    val cover: String? = null,
    var phase: String = PREPARING,
    var error: String? = null,
    /** Tentatives d'un pas réseau, pour l'attente croissante. */
    var attempts: Int = 0,
    /** L'avancement de la phase en cours, 0..1 (transcodage ou octets déposés). */
    var progress: Float = 0f,
) {
    companion object {
        const val PREPARING = "preparing"
        const val UPLOADING = "uploading"
        const val WAITING = "waiting"
        const val REGISTERING = "registering"
        const val DONE = "done"
        const val FAILED = "failed"
        const val CANCELLED = "cancelled"

        private val gson: Gson = GsonBuilder().disableHtmlEscaping().create()

        fun fromJson(text: String): PublishJob = gson.fromJson(text, PublishJob::class.java)
    }

    fun toJson(): String = gson.toJson(this)

    val isActive: Boolean
        get() = phase != DONE && phase != FAILED && phase != CANCELLED

    /** Tous les fichiers à déposer (médias et couvertures), dans l'ordre des places. */
    val files: List<PublishFile>
        get() = media.flatMap { m -> listOfNotNull(m.file, m.poster) }

    /** Ce que le Dart affiche : un instantané sans secret. */
    fun snapshot(released: Boolean): Map<String, Any?> = mapOf(
        "id" to id,
        "kind" to kind,
        "aspectW" to aspectW,
        "aspectH" to aspectH,
        "cover" to cover,
        "phase" to phase,
        "released" to released,
        "progress" to progress,
        "error" to error,
        "createdAt" to createdAt,
    )
}

/** Ce que « Publier » dépose : la légende et les droits. Écrit par l'app seulement. */
data class Release(
    val caption: String? = null,
    val captionFont: String? = null,
    val isPublic: Boolean = false,
    val shareable: Boolean = false,
    val saveable: Boolean = false,
) {
    fun toJson(): String = gson.toJson(this)

    companion object {
        private val gson = GsonBuilder().disableHtmlEscaping().serializeNulls().create()
        fun fromJson(text: String): Release = gson.fromJson(text, Release::class.java)
    }
}

/** Un média de la publication : une photo déjà rendue, ou une vidéo à transcoder. */
data class PublishMedia(
    val slot: Int,
    val isVideo: Boolean,
    val width: Int,
    val height: Int,
    /** Vidéo : la source (copie de la galerie) et ses paramètres ; nuls pour une photo. */
    val source: String? = null,
    val transcode: TranscodeSpec? = null,
    /** Vidéo : l'instant de la couverture, relatif au début du rognage. */
    val coverMs: Int = 0,
    /** Vidéo : la durée maximale admise (album 60 s, Flow 3 min). */
    val maxDurationMs: Int = 0,
    /** Rempli après le transcodage. */
    var durationMs: Int? = null,
    /** Le fichier à déposer : la photo rendue (dès le dépôt) ou la vidéo transcodée. */
    val file: PublishFile,
    /** Vidéo : la couverture, extraite du fichier produit. */
    val poster: PublishFile? = null,
) {
    /** Le transcodage est fait quand la vidéo porte sa durée. */
    val transcoded: Boolean get() = !isVideo || durationMs != null
}

/** Les paramètres du transcodeur, tels que `AlbumExport.videoSpec` les calcule. */
data class TranscodeSpec(
    val startMs: Int,
    val endMs: Int,
    val corners: List<Float>,
    val outWidth: Int,
    val outHeight: Int,
    val uniforms: List<Float>,
    val overlayPath: String?,
    val rotation: Int,
)

/** Un fichier à sceller puis déposer, et où il en est. */
data class PublishFile(
    /** La place dans le contenu (0..19, ou 100+n pour une couverture). */
    val contentSlot: Int,
    /** Le clair : rendu (photo), transcodé (vidéo) ou extrait (couverture). */
    val clear: String,
    /** Le scellé, à côté ; existe quand [sealed]. */
    val sealed: String,
    /** Le chemin dans le coffre (`<owner>/<item>_<slot>.<ext>`). */
    val storagePath: String,
    var isSealed: Boolean = false,
    /** L'URL de reprise TUS, une fois la session ouverte. */
    var uploadUrl: String? = null,
    var uploaded: Boolean = false,
)
