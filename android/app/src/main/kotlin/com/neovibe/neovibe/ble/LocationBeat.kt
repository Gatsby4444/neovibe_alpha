package com.neovibe.neovibe.ble

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.neovibe.neovibe.publish.SessionStore
import com.neovibe.neovibe.publish.SupabaseHttp
import java.util.concurrent.Executors

/**
 * **Le battement de position : mesurer où l'on est, et republier la balise.**
 *
 * ## 🔴 Le trou que ce fichier bouche — relevé le 2026-09-22
 *
 * Jusqu'ici, la balise `ping_beacons` était publiée **par le Dart**, toutes
 * les 60 s, et seulement app ouverte. Or le jeton public que la radio crie ne
 * vaut **rien** sans cette balise : c'est elle qui permet au serveur de le
 * traduire en personne. Conséquence jamais écrite noir sur blanc :
 *
 * > fermer l'app rendait invisible aux inconnus au bout de cinq minutes
 * > (`ProximityService.graceBattement`), **en silence**.
 *
 * Le croisement d'**amis**, lui, n'a jamais eu besoin de rien : il est en BLE
 * pur, le plan porte douze heures de jetons, aucun serveur n'intervient.
 *
 * ## Le scénario que ça rend vrai (Jay, 2026-09-22)
 *
 * *« Alice a activé le ping et le nouvel interrupteur "visible pour les
 * inconnus en arrière-plan" puis a fermé NeoVibe ; Bob est à portée BLE
 * d'Alice qui émet toujours son identifiant public → Bob voit Alice. »*
 * Sans ce fichier, Bob entend le jeton d'Alice et le serveur ne sait pas à
 * qui il appartient : Bob ne voit rien.
 *
 * ## ⚠️ Un seul écrivain de `ping_beacons`
 *
 * Règle 4 de `CLAUDE.md` — « un chemin, une donnée ». Ce battement **remplace**
 * la publication du Dart, il ne s'y ajoute pas : deux écrivains, ce serait deux
 * mesures de position, deux cadences, et un désaccord que rien ne signalerait.
 * Le Dart garde ce qui est de l'**usage** : la liste des voisins et le
 * groupage des jetons entendus.
 *
 * ## Ce qu'il ne décide pas
 *
 * Ni le droit d'être visible, ni la cadence : [ProximityService] les lui donne
 * (`ScreenState` pour la cadence, l'intention déposée avec le plan pour le
 * droit). Il ne renouvelle pas le jeton d'authentification : quand le serveur
 * refuse, il **compte l'échec** et continue — l'app relancera avec une session
 * fraîche à sa prochaine ouverture.
 *
 * ## ⚠️ Pourquoi il n'y a pas de second service
 *
 * [ProximityService] est **déjà** un service de premier plan de type
 * `location`, avec sa notification. Un service de plus, ce serait une
 * notification de plus pour la même chose. Et c'est ce statut qui rend une
 * position par minute tenable écran éteint : un service de premier plan n'est
 * pas soumis au sommeil profond (Doze), là où une alarme est plafonnée à un
 * réveil par ~9 min et `WorkManager` à 15 min.
 */
class LocationBeat(
    private val context: Context,
    /**
     * Le jeton public du créneau courant et son numéro, ou `null` s'il n'y a
     * rien à publier (découverte éteinte, plan épuisé).
     * Voir [AdvertSchedule.publicTokenAt].
     */
    private val jetonCourant: () -> Pair<ByteArray, Long>?,
) {
    companion object {
        /** Écran allumé : ce que demande « position continue ». */
        const val RAPIDE_MS = 30_000L

        /** Écran éteint : le « toutes les 1 min » de `RAPPELS.md` #158. */
        const val LENT_MS = 60_000L

        /**
         * Au-delà, la position en mémoire ne vaut plus la peine d'être
         * publiée : le serveur afficherait quelqu'un là où il n'est plus.
         * Même valeur que l'événement (`EventPresenceService.STALE_MS`).
         */
        const val PERIMEE_MS = 5 * 60_000L

        fun hex(bytes: ByteArray): String {
            val sb = StringBuilder(bytes.size * 2)
            for (b in bytes) sb.append(String.format("%02x", b))
            return sb.toString()
        }
    }

    private val sessions by lazy { SessionStore(context) }
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var last: Location? = null
    private var listening = false
    private var cadence = 0L

    // ------------------------------------------------------------------
    // Les instruments — sans eux, « ça a tourné la nuit » est invérifiable
    // ------------------------------------------------------------------

    /**
     * `elapsedRealtime` de la dernière publication **réussie**. Zéro = jamais.
     *
     * ⚠️ C'est la mesure qui dit si ce fichier sert à quelque chose. Une nuit
     * de huit heures écran éteint doit en compter ~480 (voir [publications]).
     */
    @Volatile
    var dernierePublication = 0L
        private set

    @Volatile
    var publications = 0
        private set

    /** Publications refusées ou impossibles, par cause — lu au diagnostic. */
    @Volatile
    var echecs = 0
        private set

    @Volatile
    var dernierEchec: String? = null
        private set

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val prev = last
            // Le meilleur des deux fournisseurs : le plus précis s'il est
            // récent, sinon le plus récent. (Même règle que l'événement.)
            last = if (prev == null || location.accuracy <= prev.accuracy ||
                location.time - prev.time > 30_000L
            ) {
                location
            } else {
                prev
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val tick = object : Runnable {
        override fun run() {
            publie()
            if (cadence > 0L) main.postDelayed(this, cadence)
        }
    }

    /**
     * Démarre ou **change de cadence**. Appeler avec la même valeur est sans
     * effet : reposer le tick à chaque passage de main décalerait le battement
     * indéfiniment, et il ne publierait jamais.
     */
    fun start(cadenceMs: Long) {
        if (!hasPermission()) return
        if (cadence == cadenceMs && listening) return
        cadence = cadenceMs
        startListening()
        main.removeCallbacks(tick)
        main.post(tick)
    }

    fun stop() {
        cadence = 0L
        main.removeCallbacks(tick)
        stopListening()
    }

    fun dispose() {
        stop()
        worker.shutdownNow()
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun startListening() {
        if (listening) return
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            runCatching {
                if (lm.isProviderEnabled(provider)) {
                    lm.requestLocationUpdates(
                        provider,
                        cadence / 2,
                        0f,
                        listener,
                        Looper.getMainLooper(),
                    )
                    lm.getLastKnownLocation(provider)?.let { listener.onLocationChanged(it) }
                }
            }
        }
        listening = true
    }

    private fun stopListening() {
        if (!listening) return
        runCatching {
            (context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)
                ?.removeUpdates(listener)
        }
        listening = false
    }

    /** Dépose la balise. **Constate et compte** ; ne décide de rien d'autre. */
    private fun publie() {
        val fix = last
        if (fix == null || System.currentTimeMillis() - fix.time > PERIMEE_MS) {
            note("no_fix")
            return
        }
        val jeton = jetonCourant()
        if (jeton == null) {
            note("no_token")
            return
        }
        val session = sessions.read()
        if (session == null) {
            note("no_session")
            return
        }
        val (token, slot) = jeton
        worker.execute {
            try {
                val body = "{\"p_lat\":${fix.latitude},\"p_lon\":${fix.longitude}," +
                    "\"p_acc\":${fix.accuracy},\"p_token\":\"${hex(token)}\",\"p_slot\":$slot}"
                SupabaseHttp(session).rpcText("publish_ping_beacon", body)
                publications++
                dernierePublication = android.os.SystemClock.elapsedRealtime()
                dernierEchec = null
            } catch (e: Exception) {
                // ⚠️ On ne s'arrête PAS sur un refus, contrairement au service
                // d'événement : ici personne ne nous relancera avant que
                // l'utilisateur rouvre l'app. Un jeton expiré se répare tout
                // seul à la prochaine ouverture ; un réseau coupé revient.
                note(e.javaClass.simpleName)
            }
        }
    }

    private fun note(cause: String) {
        echecs++
        dernierEchec = cause
    }
}
