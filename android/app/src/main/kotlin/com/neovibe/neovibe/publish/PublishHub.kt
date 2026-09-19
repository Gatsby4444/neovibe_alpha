package com.neovibe.neovibe.publish

import java.util.concurrent.CopyOnWriteArraySet

/**
 * **Le point de rencontre entre le service et le pont** — le service publie
 * ce qu'il constate (l'état de chaque publication), le pont, s'il existe,
 * le transmet au Dart. Le service ne sait pas si quelqu'un écoute, et ne
 * change rien à ce qu'il fait selon la réponse : règle « dissocier
 * l'acquisition de l'usage ».
 *
 * Le pont naît et meurt avec l'activité ; le service, non. Un `object` est
 * ce qui leur survit à tous les deux dans le processus.
 */
object PublishHub {
    interface Listener {
        /** L'état de toutes les publications rangées (voir [PublishJob.snapshot]). */
        fun onSnapshot(jobs: List<Map<String, Any?>>)

        /** Le serveur a refusé le jeton : l'app doit en déposer un frais. */
        fun onNeedToken()
    }

    private val listeners = CopyOnWriteArraySet<Listener>()

    /** Le dernier état publié, pour un pont qui s'attache après coup. */
    @Volatile
    var last: List<Map<String, Any?>> = emptyList()
        private set

    fun add(l: Listener) {
        listeners.add(l)
    }

    fun remove(l: Listener) {
        listeners.remove(l)
    }

    fun snapshot(jobs: List<Map<String, Any?>>) {
        last = jobs
        for (l in listeners) runCatching { l.onSnapshot(jobs) }
    }

    fun needToken() {
        for (l in listeners) runCatching { l.onNeedToken() }
    }
}
