package com.neovibe.neovibe

import android.content.Context
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Journal PERSISTANT du chantier caméra.
 *
 * Le double flux plante l'app : un log en mémoire (ou un simple `Log.d`)
 * disparaît avec le processus, et Jay n'a pas de PC branché pour lire le
 * logcat. Tout est donc écrit **immédiatement sur disque** (espace privé de
 * l'app), y compris le crash lui-même (handler d'exception non rattrapée
 * installé au démarrage). Au redémarrage, Réglages → Développeur →
 * « Journal caméra » affiche le fichier avec un bouton Copier.
 *
 * Écriture synchrone volontaire : on préfère quelques millisecondes de plus à
 * un log perdu au moment précis du crash.
 */
object CamLog {

    private const val MAX_BYTES = 256 * 1024
    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val lock = Any()

    private var file: File? = null

    fun init(context: Context) {
        synchronized(lock) {
            if (file != null) return
            file = File(context.filesDir, "neovibe_camera.log")
            trimIfNeeded()
        }
        installCrashHandler()
        i(
            "app",
            "démarrage — ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} " +
                "(Android ${android.os.Build.VERSION.RELEASE}, SDK " +
                "${android.os.Build.VERSION.SDK_INT})",
        )
    }

    fun i(tag: String, message: String) = write("I", tag, message)

    fun e(tag: String, message: String, error: Throwable? = null) {
        write("E", tag, message)
        if (error != null) write("E", tag, stackOf(error))
    }

    fun read(): String = synchronized(lock) {
        val f = file ?: return "(journal indisponible)"
        if (!f.exists()) return "(journal vide)"
        runCatching { f.readText() }.getOrElse { "(lecture impossible : ${it.message})" }
    }

    fun clear() = synchronized(lock) {
        runCatching { file?.writeText("") }
        Unit
    }

    private fun write(level: String, tag: String, message: String) {
        val line = "${stamp.format(Date())} $level/$tag [${Thread.currentThread().name}] $message"
        Log.i("NeoVibeCam", line)
        synchronized(lock) {
            val f = file ?: return
            runCatching { f.appendText(line + "\n") }
        }
    }

    /** Garde la moitié récente quand le fichier dépasse la taille max. */
    private fun trimIfNeeded() {
        val f = file ?: return
        runCatching {
            if (f.exists() && f.length() > MAX_BYTES) {
                val kept = f.readText().takeLast(MAX_BYTES / 2)
                f.writeText("(…début du journal tronqué…)\n$kept")
            }
        }
    }

    /**
     * Le crash est justement l'information la plus utile : on l'écrit avant de
     * laisser Android tuer le processus (le handler par défaut est ensuite
     * rappelé — on ne change pas le comportement de l'app).
     */
    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            write("F", "crash", "EXCEPTION NON RATTRAPÉE sur « ${thread.name} »")
            write("F", "crash", stackOf(error))
            previous?.uncaughtException(thread, error)
        }
    }

    private fun stackOf(error: Throwable): String {
        val out = StringWriter()
        error.printStackTrace(PrintWriter(out))
        return out.toString().trim()
    }
}
