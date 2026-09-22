package com.neovibe.neovibe.ble

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
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
 * (l'intention déposée avec le plan pour le droit ; [CADENCE_MS] pour le
 * rythme). Il ne renouvelle pas le jeton d'authentification : quand le serveur
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
 *
 * ## 🔴 Par RAFALES, et non en continu — décision de Jay, 2026-09-22 au soir
 *
 * Sa question : *« app fermée on continue de demander la position en
 * continu ? »*. La réponse était **oui**, et c'était trop : l'abonnement au
 * moteur restait ouvert en permanence, à la précision maximale, pour ne
 * publier qu'une position par minute. **On mesurait quatre fois pour en
 * utiliser une**, et le GPS ne refroidissait jamais.
 *
 * Sa décision : *« on peut faire en continu app ouverte sur maps comme Google
 * Maps si deux amis veulent se retrouver par exemple, et lorsque l'app est
 * éteinte ou en arrière-plan, on demande la position une fois par minute mais
 * […] on ouvre pendant 10 sec le temps de bien calibrer la position et ensuite
 * on referme, toutes les 60 secondes. »*
 *
 * D'où le partage, et il suit exactement qui regarde :
 *
 * | Situation | Qui mesure | Comment |
 * |---|---|---|
 * | carte ouverte au premier plan | le Dart (`LivePosition`) | **en continu**, tant que l'écran est là |
 * | app en arrière-plan ou fermée | **ce fichier** | une **rafale de 10 s par minute**, puis on coupe |
 *
 * L'image : on démarre le moteur, on roule, on coupe — au lieu de le laisser
 * tourner au ralenti toute la nuit pour un trajet par heure. Pour ce qu'on
 * publie, le résultat est le même.
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
        /**
         * **Une mesure par minute, app fermée ou en arrière-plan.**
         *
         * ## 🔴 Ce que cette constante a remplacé, et pourquoi — 2026-09-22
         *
         * Il y en avait deux : `RAPIDE_MS` (30 s, écran allumé) et `LENT_MS`
         * (60 s, écran éteint). Elles sont **fusionnées en une seule**, sur
         * décision de Jay : *« lorsque l'app est éteinte ou en arrière-plan,
         * on demande la position une fois par minute […] toutes les 60
         * secondes »*.
         *
         * La distinction écran allumé / éteint n'avait de toute façon pas de
         * sens ici : ce battement ne tourne **que** quand le Dart s'est tu
         * depuis 90 s (`ProximityService.revoirLeBattement`), c'est-à-dire
         * quand l'app n'est plus au premier plan. Que l'écran soit allumé pour
         * une autre app ne change rien à ce qu'on doit publier.
         *
         * ⚠️ `ScreenState` continue de servir **au BLE** (le mode de scan) —
         * on n'a retiré que son effet sur ce battement-ci.
         */
        const val CADENCE_MS = 60_000L

        /**
         * **Combien de temps on garde la fenêtre ouverte** à chaque mesure.
         *
         * ## L'image : on démarre le moteur, on roule, on coupe
         *
         * Avant le 2026-09-22 au soir, l'abonnement au moteur de position
         * était ouvert **et ne se refermait jamais** : on demandait la
         * précision maximale toutes les 30 s, en permanence, pour ne publier
         * qu'une position par minute. **On mesurait quatre fois pour en
         * utiliser une**, et le GPS restait chaud toute la nuit.
         *
         * Jay, 2026-09-22 : *« on ouvre pendant 10 sec le temps de bien
         * calibrer la position et ensuite on referme, toutes les 60
         * secondes »*.
         *
         * Dix secondes, parce que c'est le temps qu'il faut au moteur pour
         * **affiner** : il répond d'abord de mémoire, puis se resserre. Une
         * fenêtre d'une seconde redonnerait la première réponse grossière —
         * le défaut de l'après-midi, revenu par la porte de l'économie.
         *
         * ⚠️ **Ce n'est pas mesuré.** Ni l'ancien coût, ni le nouveau. Le
         * rapport attendu est d'environ un sixième de temps radio, par
         * construction (10 s sur 60), mais seule une nuit comparée le dira —
         * `RAPPELS.md` #158.
         */
        const val FENETRE_MS = 10_000L

        /**
         * Le pas demande au moteur **pendant** la fenetre.
         *
         * Une seconde : on veut plusieurs releves dans les dix secondes, parce
         * que c'est leur succession qui resserre le point. Le moteur ne livre
         * de toute facon que ce qu'il a — demander plus vite ne fabrique pas
         * de mesure, mais demander plus lentement en perd.
         */
        const val PAS_FENETRE_MS = 1_000L

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

    /**
     * Le battement est-il **arme** ? A ne pas confondre avec [listening],
     * qui ne dit que si la fenetre est ouverte a cet instant - dix secondes
     * par minute depuis la rafale. Voir la garde de [start].
     */
    private var arme = false

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

    /**
     * **Un tour : on ouvre la fenêtre, on écoute, on referme, on publie.**
     *
     * L'ordre compte. Publier **à la fermeture** et non à l'ouverture est
     * toute la différence : à l'ouverture on n'aurait que le point gardé du
     * tour précédent, vieux d'une minute, et les dix secondes d'écoute ne
     * serviraient à rien — on paierait la radio sans en tirer le bénéfice.
     */
    private val tick = object : Runnable {
        override fun run() {
            startListening()
            main.postDelayed(ferme, FENETRE_MS)
            if (cadence > 0L) main.postDelayed(this, cadence)
        }
    }

    /** La fermeture de la fenêtre : on coupe la radio, **puis** on publie. */
    private val ferme = Runnable {
        stopListening()
        publie()
    }

    /**
     * Démarre ou **change de cadence**. Appeler avec la même valeur est sans
     * effet : reposer le tick à chaque passage de main décalerait le battement
     * indéfiniment, et il ne publierait jamais.
     */
    /**
     * Démarre ou **change de cadence**. Appeler avec la même valeur alors
     * qu'un tour est déjà armé est sans effet : reposer le minuteur à chaque
     * passage de main décalerait le battement indéfiniment, et il ne
     * publierait jamais.
     *
     * ⚠️ **`arme` remplace `listening` dans cette garde** — 2026-09-22 au
     * soir. La garde lisait « écoute-t-on ? », ce qui était équivalent tant
     * que l'abonnement restait ouvert en permanence. Depuis la rafale, on
     * n'écoute que dix secondes par minute : cinquante secondes sur soixante,
     * `listening` est faux alors que tout va bien, et la garde laissait passer
     * — le battement se reposait à chaque appel et **n'aurait jamais publié**.
     * Deux questions différentes derrière un même mot (règle du fichier
     * `CLAUDE.md` sur les mots proches).
     */
    fun start(cadenceMs: Long) {
        if (!hasPermission()) return
        if (cadence == cadenceMs && arme) return
        cadence = cadenceMs
        arme = true
        // La cadence a changé : on repart d'un tour propre plutôt que de
        // laisser cohabiter l'ancien minuteur et le nouveau.
        main.removeCallbacks(tick)
        main.removeCallbacks(ferme)
        stopListening()
        main.post(tick)
    }

    fun stop() {
        cadence = 0L
        arme = false
        main.removeCallbacks(tick)
        // ⚠️ **La fermeture de fenêtre en attente s'annule aussi.** Sans ça,
        // elle se déclencherait jusqu'à dix secondes après l'arrêt et
        // publierait une balise que plus personne n'a demandée.
        main.removeCallbacks(ferme)
        stopListening()
    }

    fun dispose() {
        stop()
        worker.shutdownNow()
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * **Quel moteur mesure la position** : `google`, `android`, ou `aucun`.
     *
     * ## ⚠️ Pourquoi c'est publié et pas déduit
     *
     * Les deux moteurs rendent le même objet [Location], avec les mêmes
     * champs. Une position fusionnée par Google et une position d'antenne
     * brute ont **exactement la même apparence** — seule leur incertitude
     * diffère, et une incertitude seule ne dit pas qui l'a produite.
     *
     * Le 2026-09-22, il a fallu lire le code d'un paquet pour savoir lequel
     * répondait. Ça ne se reproduit pas : le diagnostic le dit.
     */
    @Volatile
    var moteur = "aucun"
        private set

    private var fused: FusedLocationProviderClient? = null

    private val rappelGoogle = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.lastLocation?.let { listener.onLocationChanged(it) }
        }
    }

    /**
     * On écoute avec le **moteur de Google** si le téléphone l'a, sinon avec
     * celui d'Android. Pas un choix de confort : voir [demarreGoogle].
     */
    private fun startListening() {
        if (listening) return
        listening = demarreGoogle() || demarreAndroid()
        if (!listening) moteur = "aucun"
    }

    /**
     * **Le moteur fusionné de Google** — celui qui sert Google Maps et Snap.
     *
     * ## 🔴 Ce qu'il change, et pourquoi on a mis un mois à le voir
     *
     * [LocationManager] (ci-dessous) ne croise **rien** : il rend le GPS brut,
     * ou l'estimation d'antenne brute. Sous terre, dans un bâtiment, dans une
     * rue étroite, ça fait des centaines de mètres. Le moteur de Google croise
     * GPS, Wi-Fi, antennes et capteurs, et s'appuie sur la base de données
     * Wi-Fi mondiale de Google.
     *
     * Constaté par Jay le 2026-09-22, dans le métro : NeoVibe à deux rues de
     * l'endroit réel, Google Maps juste, au même instant sur le même téléphone.
     *
     * ⚠️ **`setWaitForAccurateLocation(false)`, volontairement.** Demander à
     * n'être réveillé que sur une position précise ferait taire le moteur tant
     * qu'il n'a rien de bon — or on préfère un point médiocre tout de suite
     * **et** les meilleurs ensuite : c'est [listener] qui garde le meilleur.
     * Laisser le tri au moteur, c'est lui déléguer une décision d'usage.
     *
     * @return `false` si les services Google Play manquent — Huawei, ROM
     *   chinoise, appareil dégooglisé. Ce n'est pas une panne : c'est le cas
     *   où [demarreAndroid] est la seule option, et il faut alors que le
     *   diagnostic le dise plutôt que d'afficher une position sans auteur.
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
            // ⚠️ **L'intervalle est celui de la FENÊTRE, pas celui du
            // battement** — corrigé le 2026-09-22 au soir avec le passage à la
            // rafale. Il valait `cadence / 2` : une fenêtre de dix secondes
            // aurait demandé un relevé toutes les trente, donc **zéro ou un**,
            // et les dix secondes n'auraient rien affiné. On veut au contraire
            // le maximum de relevés PENDANT la fenêtre, pour que le point se
            // resserre — c'est toute la raison de l'ouvrir.
            val requete = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, PAS_FENETRE_MS)
                .setMinUpdateIntervalMillis(PAS_FENETRE_MS)
                .setWaitForAccurateLocation(false)
                .setMaxUpdateAgeMillis(FENETRE_MS)
                .build()
            client.requestLocationUpdates(requete, rappelGoogle, Looper.getMainLooper())
            // Ce que le moteur tient déjà : sans ça, le premier battement après
            // un démarrage n'a rien à publier et compte un `no_fix` pour rien.
            client.lastLocation.addOnSuccessListener { p ->
                p?.let { listener.onLocationChanged(it) }
            }
            moteur = "google"
            true
        }.getOrDefault(false)
    }

    /**
     * Le moteur d'Android, **en repli seulement**. Voir [demarreGoogle] pour ce
     * qu'il ne sait pas faire.
     */
    private fun demarreAndroid(): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        // Nommee `pose` et non `arme` : `arme` est desormais un CHAMP de la
        // classe (le battement est-il arme ?). Une locale du meme nom le
        // masquerait ici sans que Kotlin ne dise rien, et la prochaine
        // personne a lire ce fichier croirait modifier l'etat du battement.
        var pose = false
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            runCatching {
                if (lm.isProviderEnabled(provider)) {
                    lm.requestLocationUpdates(
                        provider,
                        PAS_FENETRE_MS,
                        0f,
                        listener,
                        Looper.getMainLooper(),
                    )
                    lm.getLastKnownLocation(provider)?.let { listener.onLocationChanged(it) }
                    pose = true
                }
            }
        }
        if (pose) moteur = "android"
        return pose
    }

    /**
     * ⚠️ **Les deux moteurs sont coupés, pas seulement celui qui tournait.**
     * Règle 8 de `CLAUDE.md` : un abonnement qu'on croit arrêté parce qu'on a
     * arrêté l'autre continue de réveiller la radio, et rien ne le signale —
     * la batterie descend, c'est tout.
     */
    private fun stopListening() {
        if (!listening) return
        runCatching { fused?.removeLocationUpdates(rappelGoogle) }
        runCatching {
            (context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)
                ?.removeUpdates(listener)
        }
        listening = false
        moteur = "aucun"
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
