package com.neovibe.neovibe.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/**
 * **Le moteur de position, en un seul exemplaire** (2026-09-25).
 *
 * Il servait deux fois, écrit deux fois : dans le battement de proximité
 * ([com.neovibe.neovibe.ble.LocationBeat]) et dans la présence en soirée
 * ([com.neovibe.neovibe.events.EventPresenceService]). La leçon du métro
 * (2026-09-22 : passer au moteur de Google) avait été portée dans le premier
 * et **oubliée dans le second** — trois jours de présence figée en soirée,
 * constatés par Jay le 2026-09-25. Deux copies, c'est une correction sur
 * deux. Ici, une seule.
 *
 * ## Ce qu'il fait, et rien d'autre
 *
 * La **cuisine** : il écoute, et garde **le meilleur point** reçu (le plus
 * précis s'il est récent, sinon le plus récent). Il ne décide ni quand
 * publier, ni si un point est trop vieux pour servir, ni à qui l'envoyer :
 * c'est l'affaire de chaque service, avec ses propres règles.
 *
 * ## Les deux moteurs
 *
 * - **Google** (fusionné : GPS + Wi-Fi + antennes + capteurs, avec la base
 *   Wi-Fi mondiale de Google) — celui de Google Maps. Toujours d'abord.
 * - **Android** ([LocationManager] : GPS brut, antenne brute) — **en repli
 *   seulement**, sur un appareil sans services Google (Huawei, ROM
 *   dégooglisée). Dans un bâtiment ou sous terre, il se trompe de centaines
 *   de mètres, ou ne rend plus rien après le premier point.
 *
 * ⚠️ **`setWaitForAccurateLocation(false)`, volontairement.** Demander à
 * n'être réveillé que sur une position précise ferait taire le moteur tant
 * qu'il n'a rien de bon — on préfère un point médiocre tout de suite **et**
 * les meilleurs ensuite : c'est [garde] qui trie. Laisser le tri au moteur,
 * c'est lui déléguer une décision d'usage.
 *
 * @param intervalMs le pas demandé au moteur de Google.
 * @param minIntervalMs le pas le plus court qu'il a le droit de livrer.
 * @param maxAgeMs l'âge maximal d'un point livré par Google ; nul = son défaut.
 * @param androidIntervalMs le pas demandé au moteur d'Android, en repli.
 */
class PositionEngine(
    private val context: Context,
    private val intervalMs: Long,
    private val minIntervalMs: Long,
    private val maxAgeMs: Long?,
    private val androidIntervalMs: Long,
) {

    /** Le meilleur point reçu. Survit à [stop] : c'est la dernière mesure. */
    @Volatile
    var last: Location? = null
        private set

    /** L'écoute est-elle ouverte à cet instant ? */
    var listening = false
        private set

    /**
     * **Quel moteur mesure la position** : `google`, `android`, ou `aucun`.
     *
     * Publié et non déduit : une position fusionnée par Google et une
     * position d'antenne brute ont **exactement la même apparence** — seule
     * leur incertitude diffère, et une incertitude seule ne dit pas qui l'a
     * produite. Le 2026-09-22, il a fallu lire le code d'un paquet pour savoir
     * lequel répondait ; depuis, les diagnostics le disent.
     */
    @Volatile
    var moteur = "aucun"
        private set

    private var fused: FusedLocationProviderClient? = null

    /** Le meilleur des points : le plus précis s'il est récent, sinon le plus récent. */
    private fun garde(location: Location) {
        val prev = last
        last = if (prev == null || location.accuracy <= prev.accuracy ||
            location.time - prev.time > 30_000L
        ) {
            location
        } else {
            prev
        }
    }

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) = garde(location)

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val rappelGoogle = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.lastLocation?.let { garde(it) }
        }
    }

    /**
     * Ouvre l'écoute : Google s'il est là, Android sinon. Sans effet si elle
     * est déjà ouverte.
     *
     * @return `false` sans permission, ou si aucun moteur n'a accepté.
     */
    fun start(): Boolean {
        if (listening) return true
        if (!hasPermission()) return false
        listening = demarreGoogle() || demarreAndroid()
        if (!listening) moteur = "aucun"
        return listening
    }

    /**
     * ⚠️ **Les deux moteurs sont coupés, pas seulement celui qui tournait.**
     * Règle 8 de `CLAUDE.md` : un abonnement qu'on croit arrêté parce qu'on a
     * arrêté l'autre continue de réveiller la radio, et rien ne le signale —
     * la batterie descend, c'est tout.
     */
    fun stop() {
        if (!listening) return
        runCatching { fused?.removeLocationUpdates(rappelGoogle) }
        runCatching {
            (context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)
                ?.removeUpdates(listener)
        }
        listening = false
        moteur = "aucun"
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * @return `false` si les services Google Play manquent. Ce n'est pas une
     *   panne : c'est le cas où [demarreAndroid] est la seule option, et le
     *   diagnostic le dit par [moteur].
     */
    @SuppressLint("MissingPermission")
    private fun demarreGoogle(): Boolean {
        val dispo = runCatching {
            GoogleApiAvailability.getInstance()
                .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
        }.getOrDefault(false)
        if (!dispo) return false
        return runCatching {
            val client = fused
                ?: LocationServices.getFusedLocationProviderClient(context)
                    .also { fused = it }
            val requete = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
                .setMinUpdateIntervalMillis(minIntervalMs)
                .setWaitForAccurateLocation(false)
                .apply { maxAgeMs?.let { setMaxUpdateAgeMillis(it) } }
                .build()
            client.requestLocationUpdates(requete, rappelGoogle, Looper.getMainLooper())
            // Ce que le moteur tient déjà : sans ça, la première mesure après
            // un démarrage n'a rien à rendre.
            client.lastLocation.addOnSuccessListener { p -> p?.let { garde(it) } }
            moteur = "google"
            true
        }.getOrDefault(false)
    }

    @SuppressLint("MissingPermission")
    private fun demarreAndroid(): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        var pose = false
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            runCatching {
                if (lm.isProviderEnabled(provider)) {
                    lm.requestLocationUpdates(
                        provider,
                        androidIntervalMs,
                        0f,
                        listener,
                        Looper.getMainLooper(),
                    )
                    lm.getLastKnownLocation(provider)?.let { garde(it) }
                    pose = true
                }
            }
        }
        if (pose) moteur = "android"
        return pose
    }
}
