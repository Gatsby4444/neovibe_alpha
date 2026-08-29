package com.neovibe.neovibe.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Le point de rendez-vous entre le pont et le service.
 *
 * ## Pourquoi il existe — le défaut du 2026-08-16, relevé par Jay au test
 *
 * Le pont s'enregistrait auprès du service par `ProximityService.instance?.bridge = this`,
 * **au moment où le Dart s'abonne au flux**. Or, à cet instant, le service
 * n'existe pas encore : il ne démarre qu'à l'appel de `start`, plus tard. Le
 * `?.` avalait donc l'affectation **en silence**, et le service tournait ensuite
 * pour toujours sans destinataire.
 *
 * Symptômes, tous expliqués par cette seule ligne : la notification disait vrai
 * (le moteur, lui, savait), l'écran restait bloqué sur « Démarrage… » (aucun
 * état ne remontait), et rien n'était jamais détecté (aucun scan ne remontait
 * non plus).
 *
 * ⚠️ **La leçon dépasse le correctif** : deux objets dont l'un doit trouver
 * l'autre ne doivent pas dépendre de **l'ordre dans lequel ils naissent**. Ici,
 * chacun dépose et lit au même endroit ; quel que soit le premier arrivé, le
 * lien se fait. C'est la cause supprimée, pas une initialisation mieux rangée.
 */
object ProximityBus {
    @Volatile
    var listener: BleEngine.Listener? = null
}

/**
 * Le service de premier plan qui POSSÈDE la radio.
 *
 * ## Pourquoi un service, et pas l'activité
 *
 * Décision de Jay, 2026-08-16 : *« natif Kotlin, service dédié »*. Android
 * détruit une activité dès qu'il en a envie — mise en veille, changement
 * d'application, manque de mémoire. Tant que la radio appartenait à l'activité,
 * la détection s'arrêtait avec elle, **sans que rien ne le signale**.
 *
 * Ici, [BleEngine] appartient au service. L'interface peut disparaître : le scan
 * continue, l'advertising continue, et l'état reste vrai.
 *
 * ⚠️ **Ce que ce service ne fait PAS, et qu'il ne faut pas croire acquis** : il
 * ne déchiffre rien et ne répond à aucune poignée de main. Le protocole vit en
 * Dart. Quand l'interface est absente, la radio continue de **voir** et de
 * **retenir** (voir [pendingScans]), mais une révélation d'inconnu, elle,
 * attendra le retour du Dart. Étendre le protocole au natif est un chantier en
 * soi, et il n'aurait de toute façon pas d'équivalent iOS.
 */
class ProximityService : Service(), BleEngine.Listener {

    companion object {
        private const val CHANNEL_ID = "neovibe_proximity"
        private const val NOTIFICATION_ID = 4201

        const val ACTION_START = "com.neovibe.proximity.START"
        const val ACTION_STOP = "com.neovibe.proximity.STOP"
        const val EXTRA_ADVERT_ID = "advertId"

        /**
         * L'instance vivante, si le service tourne.
         *
         * Même processus des deux côtés : un binder n'apporterait rien qu'une
         * indirection. Ce qui compte est que le pont Dart soit **remplaçable à
         * chaud** — l'interface peut mourir et renaître plusieurs fois pendant
         * la vie du service.
         */
        @Volatile
        var instance: ProximityService? = null
            private set

        fun start(context: Context, advertId: ByteArray) {
            val intent = Intent(context, ProximityService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ADVERT_ID, advertId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ProximityService::class.java).apply { action = ACTION_STOP },
            )
        }
    }

    /** Le pont vers le Dart, quand il y en a un. Publié par [ProximityBus]. */
    private val bridge: BleEngine.Listener? get() = ProximityBus.listener

    private lateinit var engine: BleEngine
    private var lastStatus: RadioStatus = RadioStatus.Idle

    /**
     * Ce que la radio a vu pendant que l'interface était absente.
     *
     * Borné à [SCAN_BUFFER_MAX] : on veut savoir *que* quelqu'un est passé, pas
     * rejouer une heure de scan. Au-delà, les plus anciennes tombent — une
     * mémoire non bornée dans un service qui vit des jours est une fuite.
     */
    private data class BufferedScan(
        val address: String,
        val advertId: ByteArray,
        val rssi: Int,
        val txPower: Int,
        val type: Byte,
        /**
         * ⚠️ **Le champ qui manquait, et il rendait le rejeu MENSONGER.**
         *
         * Sans date, une annonce captee il y a des heures etait rejouee au
         * retour de l'interface comme une observation faite maintenant : le
         * pair reapparaissait « a portee », et une notification « Le presque… »
         * partait pour quelqu'un qui n'etait plus la depuis longtemps.
         *
         * On publie donc QUAND on a entendu ; c'est au consommateur de decider
         * si c'est encore une presence ou seulement un souvenir.
         */
        val atMillis: Long,
    )

    private val pendingScans = ConcurrentLinkedQueue<BufferedScan>()
    private val scanBufferMax = 200

    // ------------------------------------------------------------------
    // Le plan d'emission — la correction du point H
    // ------------------------------------------------------------------

    /**
     * Ce que le Dart nous a laisse a crier, et pour combien de temps.
     *
     * ⚠️ **C'est ce qui rend ce service independant du Dart.** Avant, le Dart
     * poussait un identifiant a chaque changement de creneau ; s'il mourait,
     * l'identifiant se figeait et l'appareil devenait invisible pour tous ses
     * amis sans que rien ne le signale. Ici le Dart depose des heures d'avance,
     * et nous choisissons nous-memes.
     */
    @Volatile
    private var schedule: AdvertSchedule? = null

    private var cursor = 0
    private val cycleHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * Cadence de rotation a l'interieur d'un creneau.
     *
     * Chaque changement d'annonce coute un arret/relance de l'advertising. A un
     * seul jeu d'annonces, il faut donc arbitrer entre « chaque ami me voit
     * vite » et « la radio ne passe pas son temps a redemarrer ».
     *
     * ⚠️ **Valeur RAISONNEE, pas mesuree** (2026-08-20) : le cout reel d'un
     * redemarrage d'advertising n'a pas ete releve sur appareil. A confronter au
     * terrain avant de la figer.
     */
    private val cycleMillis = 400L

    private val cycleTick = object : Runnable {
        override fun run() {
            emitNext()
            cycleHandler.postDelayed(this, nextDelay())
        }
    }

    /**
     * Dans combien de temps se reveiller.
     *
     * ⚠️ **Trois cadences, et une seule raison a chacune.** En mode parallele
     * tous les jetons sont deja en l'air : il suffit d'etre la au changement de
     * creneau, donc 30 s. Avec un seul jeton, idem. C'est uniquement le mode
     * cycle qui doit tourner vite, parce qu'il n'annonce qu'un ami a la fois.
     */
    private fun nextDelay(): Long {
        val plan = schedule
        if (parallel) return 30_000L
        return if (plan == null || plan.cycleLength <= 1) 30_000L else cycleMillis
    }

    /**
     * Vrai quand le moteur emet tous les jetons **en meme temps**.
     *
     * ⚠️ **C'est un fait constate, pas une preference.** Le moteur decide de
     * ce que le materiel accepte ; ce service ne fait qu'en tenir compte pour
     * choisir sa cadence. Voir [BleEngine.applyAdverts].
     */
    private var parallel = false

    // ------------------------------------------------------------------
    // L'HOMME MORT de l'identifiant public
    // ------------------------------------------------------------------

    /**
     * Dernier signe de vie du Dart **concernant la decouverte**, en
     * `elapsedRealtime`. Zero = jamais.
     */
    @Volatile
    private var dernierBattement = 0L

    /**
     * Combien de temps on continue de crier l'identifiant public **apres** le
     * dernier signe de vie.
     *
     * ⚠️ **Ce n'est pas un chiffre choisi, c'est celui du serveur.** La balise
     * qui permet de TRADUIRE cet identifiant en personne vit cinq minutes
     * (`private.ping_beacon_ttl()`), et le Dart la republie toutes les soixante
     * secondes tant qu'il vit. Passe ce delai, plus personne au monde ne peut
     * relier ce jeton a un compte : le crier encore ne rend service a personne,
     * et laisse une trace suivable au scanner du premier venu.
     */
    private val graceBattement = 5 * 60_000L

    /**
     * Le Dart est vivant et veut toujours etre decouvrable.
     *
     * Appele a chaque republication reussie de la balise serveur — c'est le
     * meme geste qui rend le jeton traduisible et qui prouve qu'on est la.
     */
    fun battementPublic() {
        dernierBattement = android.os.SystemClock.elapsedRealtime()
    }

    /**
     * A-t-on encore le droit de crier l'identifiant public ?
     *
     * ## 🔴 Le defaut que ceci corrige — audit du 2026-08-28
     *
     * Le plan porte **75 minutes** de jetons d'avance, pour que le service
     * survive seul a la mort du Dart. C'est juste pour les jetons d'AMIS : un
     * ami reconnait tout seul, sans reseau, app fermee — leur horizon est de
     * douze heures et c'est voulu.
     *
     * L'identifiant PUBLIC, lui, ne vaut rien sans la balise serveur. Quand
     * Android rangeait l'app, la balise mourait en cinq minutes et l'appareil
     * continuait de crier **jusqu'a soixante-dix minutes de plus** — un
     * identifiant que personne ne pouvait traduire, mais que n'importe quel
     * scanner pouvait suivre.
     *
     * ⚠️ **Le depot d'un plan compte comme un battement.** Le Dart qui depose
     * un plan est vivant par definition ; sans ca, allumer la decouverte
     * laisserait l'appareil muet jusqu'a la premiere republication de balise.
     */
    private fun publicAutorise(): Boolean =
        dernierBattement != 0L &&
            android.os.SystemClock.elapsedRealtime() - dernierBattement < graceBattement

    private fun emitNext() {
        val plan = schedule ?: return
        val now = System.currentTimeMillis()

        // ⚠️ **Le filtre est pose ICI, et nulle part ailleurs.** C'est le seul
        // passage par lequel un jeton atteint la radio : les deux modes
        // d'emission — parallele et cycle — partent de cette meme liste depuis
        // le 2026-08-29. Tant qu'ils la calculaient chacun de leur cote, une
        // regle posee sur l'un ne s'appliquait pas a l'autre.
        val duCreneau = plan.tokensAt(now, avecPublic = publicAutorise())
        if (duCreneau == null) {
            // ⚠️ **Plan epuise : on se TAIT.** Reemettre le dernier jeton connu
            // serait indiscernable d'un fonctionnement normal, alors que plus
            // personne ne nous reconnaitrait. Le silence, lui, se constate — et
            // il se dit.
            engine.pauseAdvertising()
            onStatus(
                RadioStatus.Failed(
                    "planExpired",
                    "Le plan d'emission est epuise : rouvre l'app pour le renouveler.",
                ),
            )
            return
        }

        if (duCreneau.first.isEmpty()) {
            // ⚠️ **Silence VOLONTAIRE, et ce n'est pas une panne.** On arrive ici
            // quand il ne restait que l'identifiant public et qu'on a perdu le
            // droit de le crier : quelqu'un qui ne voulait qu'etre decouvrable,
            // dont le Dart ne repond plus. `stats()` le dit (`publicMuted`), et
            // aucun statut d'echec n'est leve — il n'y a rien a reparer.
            engine.pauseAdvertising()
            parallel = false
            return
        }

        // ⚠️ **Le parallele d'abord, toujours.** En mode cycle, le jeton d'un
        // ami donne n'est en l'air que 1/N du temps : a dix amis, 10 %. Quelqu'un
        // qu'on croise trois secondes pouvait n'etre JAMAIS vu, et le defaut
        // s'aggravait avec le nombre d'amis - sans jamais rien lever.
        if (engine.applyAdverts(duCreneau.first, duCreneau.second)) {
            parallel = true
            return
        }
        parallel = false

        val lequel = Math.floorMod(cursor, duCreneau.first.size)
        cursor++
        engine.updateAdvert(duCreneau.first[lequel], duCreneau.second[lequel])
    }

    /** Le Dart depose un nouveau plan. Il remplace entierement le precedent. */
    fun setAdvertSchedule(plan: AdvertSchedule) {
        // ⚠️ **Deposer un plan, c'est prouver qu'on est vivant.** Voir
        // [publicAutorise] : sans cette ligne, allumer la decouverte laisserait
        // l'appareil muet jusqu'a la premiere republication de balise.
        battementPublic()
        schedule = plan
        persiste()
        cursor = 0
        cycleHandler.removeCallbacks(cycleTick)
        if (!plan.isEmpty) {
            // `emitNext` pose `parallel` : la cadence se lit donc APRES lui, et
            // pas avant. L'inverse aurait arme 400 ms un mode qui n'en a pas
            // besoin.
            emitNext()
            cycleHandler.postDelayed(cycleTick, nextDelay())
        }
    }

    /**
     * Le moteur n'a pas pu tenir le mode parallele : on reprend le cycle.
     *
     * ⚠️ **On ne se contente pas de changer de drapeau.** Le moteur vient
     * d'arreter tous ses jeux : sans un `emitNext` immediat, l'appareil resterait
     * **muet** jusqu'au prochain reveil - jusqu'a trente secondes d'invisibilite
     * totale, que rien n'aurait signalee.
     */
    override fun onParallelAdvertLost(reason: String) {
        parallel = false
        cycleHandler.removeCallbacks(cycleTick)
        emitNext()
        cycleHandler.postDelayed(cycleTick, nextDelay())
    }

    /** Jusqu'a quand le plan courant tient, pour que le Dart sache le renouveler. */
    fun scheduleValidUntil(): Long = schedule?.validUntilMillis ?: 0L

    // ------------------------------------------------------------------
    // La reconnaissance sans le Dart
    // ------------------------------------------------------------------

    @Volatile
    private var recognition: RecognitionTable? = null

    /**
     * Jetons d'ami PRIVES qui ne nous sont pas destines, ecartes.
     *
     * ⚠️ **Compte ICI, et nulle part ailleurs.** Ce sont les jetons qu'un
     * emetteur crie pour ses AUTRES amis. Les distinguer d'un jeton qu'on
     * attend demande la table de reconnaissance — que le moteur radio n'a pas.
     * Il portait pourtant ce compteur jusqu'au 2026-08-28, sans jamais
     * l'incrementer : le diagnostic affichait un zero permanent presente comme
     * une mesure.
     *
     * ⚠️ **Compte seulement quand une table existe.** Sans table, on ne peut
     * pas dire qu'un jeton nous est etranger — on peut seulement dire qu'on ne
     * sait pas. Compter ce cas ferait passer « je n'ai pas d'amis » pour « on
     * m'a crie des jetons qui ne sont pas les miens ».
     */
    @Volatile
    private var foreignTokenScans = 0

    private val sightings = SightingBuffer()

    /** Duree d'un creneau, deposee avec la table. */
    @Volatile
    private var slotMillis = 900_000L

    /**
     * Le Dart depose la table de reconnaissance. Elle remplace la precedente.
     *
     * ⚠️ Elle ne contient **aucune identite** : des jetons et des rangs. Seul le
     * Dart sait a qui correspond le rang 3, et il le sait pour CETTE table —
     * d'ou le `tableId` renvoye avec chaque constat.
     */
    fun setRecognitionTable(table: RecognitionTable, slotDurationMillis: Long) {
        recognition = table
        slotMillis = slotDurationMillis
        persiste()
    }

    /**
     * Ecrit sur le disque de quoi reprendre apres la mort du processus.
     *
     * ⚠️ **Les deux ensemble ou rien** : un plan sans table donnerait un
     * appareil vu sans voir, une table sans plan un appareil qui voit sans
     * etre vu. `PlanStore` refuse d'ecrire du partiel, et efface plutot.
     *
     * ⚠️ **L'identifiant public du ping n'y est PAS** — decision de Jay du
     * 2026-08-28. Voir `PlanStore`.
     */
    private fun persiste() {
        PlanStore.ecrire(applicationContext, schedule, recognition)
    }

    /** Rend les constats accumules et vide le tampon. */
    fun takeSightings(): List<NativeSighting> = sightings.drain()

    // ⚠️ **`sightingCount()` a ete RETIRE le 2026-08-28** : aucun appelant, ni
    // dans le pont, ni dans les tests. Le tampon se lit par `takeSightings`,
    // qui le vide — un compteur a cote aurait donne un second chiffre a tenir
    // d'accord avec le premier.

    override fun onCreate() {
        super.onCreate()
        instance = this
        engine = BleEngine(applicationContext, this)
        engine.attach()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // ⚠️ **L'arret voulu efface le plan persiste.** Sans ca, couper
                // sa visibilite laisserait sur le disque de quoi recommencer a
                // crier au prochain redemarrage du systeme — l'inverse exact de
                // ce que l'utilisateur vient de demander.
                PlanStore.effacer(applicationContext)
                reprisDuDisque = false
                engine.stop()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val advertId = intent?.getByteArrayExtra(EXTRA_ADVERT_ID)
                if (advertId == null) {
                    // Android nous a relances apres nous avoir tues : l'intent
                    // d'origine est perdu, donc l'identifiant PUBLIC aussi — il
                    // derive d'une graine que seul le Dart detient, en memoire.
                    //
                    // ⚠️ **Mais les jetons d'AMIS, eux, sont sur le disque**
                    // depuis le 2026-08-28. Avant, on s'arretait ici : « le
                    // croisement fonctionne app fermee » etait donc vrai tant
                    // que le PROCESSUS vivait, pas tant que le telephone etait
                    // allume.
                    return if (repartDuDisque()) START_STICKY else {
                        onStatus(
                            RadioStatus.Failed(
                                "restarted",
                                "Le service a ete relance par le systeme : " +
                                    "rouvre l'app pour reprendre la detection.",
                            ),
                        )
                        stopForegroundCompat()
                        stopSelf()
                        START_NOT_STICKY
                    }
                }
                // ⚠️ **Un demarrage demande par le Dart efface le plan
                // persiste.** Il s'apprete a en deposer un neuf ; garder
                // l'ancien laisserait, entre les deux, de quoi crier les jetons
                // du compte precedent apres un changement d'utilisateur.
                PlanStore.effacer(applicationContext)
                reprisDuDisque = false
                startForegroundCompat()
                engine.start(advertId)
            }
        }
        // START_STICKY : si Android nous tue sous la pression mémoire, il nous
        // relance. L'intention de l'utilisateur, elle, est relue côté Dart.
        return START_STICKY
    }

    /**
     * Vrai quand ce service tourne sur un plan relu du disque.
     *
     * ⚠️ **Publie dans `stats()`, et ce n'est pas decoratif** : dans cet etat
     * l'appareil croise ses amis mais **n'est pas decouvrable par des
     * inconnus** — il n'a pas d'identifiant public a crier. C'est le prix
     * choisi le 2026-08-28, et un prix qu'on ne voit pas est un prix qu'on
     * finit par oublier d'avoir accepte.
     */
    @Volatile
    private var reprisDuDisque = false

    /**
     * Reprend sur le plan persiste, sans le Dart.
     *
     * Rend `false` s'il n'y a rien d'exploitable — pas de fichier, ou un plan
     * qui ne couvre plus l'instant present. On ne repart alors PAS : emettre
     * des jetons perimes serait indiscernable d'une radio saine tout en ne se
     * faisant reconnaitre par personne.
     */
    private fun repartDuDisque(): Boolean {
        val repris = PlanStore.relire(applicationContext, System.currentTimeMillis())
            ?: return false
        val premier = repris.plan.tokenAt(System.currentTimeMillis(), 0) ?: return false

        reprisDuDisque = true
        startForegroundCompat()
        // ⚠️ Le premier jeton est celui d'un AMI : il part avec son vrai type,
        // sinon les autres appareils le prendraient pour un identifiant public.
        engine.start(premier, BleConstants.TYPE_FRIEND)
        setRecognitionTable(repris.table, repris.table.rawSlotMillis)
        setAdvertSchedule(repris.plan)
        return true
    }

    override fun onDestroy() {
        // Le minuteur du plan appartient a ce service : le laisser tourner apres
        // sa mort, c'est exactement le genre de noeud orphelin que ce projet
        // passe son temps a chasser.
        cycleHandler.removeCallbacks(cycleTick)
        schedule = null
        // La table et les constats appartiennent a ce service : les laisser
        // derriere serait garder une trace de qui a ete croise, sans personne
        // pour la reclamer.
        recognition = null
        sightings.clear()
        engine.detach()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------------
    // Commandes venues du Dart
    // ------------------------------------------------------------------

    // ⚠️ **`updateAdvert` a ete SUPPRIME le 2026-08-25.** C'etait un second
    // chemin vers l'emission, reste d'avant le plan d'annonces du 2026-08-20 :
    // aucun appelant Dart (verifie), et il ne pouvait pas porter le TYPE du
    // jeton. Deux chemins vers la meme radio, c'est celui qui en sait le moins
    // qui gagne un jour, en silence.
    // ⚠️ **`advertCapabilities()` a ete RETIRE le 2026-08-28**, avec le cas du
    // pont et la methode Dart qui l'appelait : aucun appelant depuis que
    // `stats()` fusionne la map entiere du moteur (2026-08-26). Un second
    // chemin vers la meme mesure, c'est deux reponses possibles a une question
    // qui n'en a qu'une.

    // ⚠️ **`connect`, `disconnect`, `send` et `mtuOf` ont ete SUPPRIMES le
    // 2026-08-27**, avec tout le bloc GATT de `BleEngine`. Le service ne relaie
    // plus aucun ordre vers la radio : il n'en remonte que des constats.

    /**
     * Ce que la radio a reellement recu depuis le dernier demarrage.
     *
     * ⚠️ **Les CAPACITES y sont fusionnees depuis le 2026-08-26**, et leur
     * absence a coute cher. `advertCapabilities()` existait depuis le
     * 2026-08-20 et n'etait joignable que par un appel Dart dedie : elle
     * n'apparaissait donc dans aucun rapport de diagnostic. Or `RAPPELS.md` #54
     * demandait explicitement d'ecrire le chemin multi-annonces **apres** avoir
     * releve ce que l'appareil de Jay annonce. La consigne etait juste, et
     * inapplicable : l'instrument ne rendait pas la mesure.
     *
     * On fusionne la map entiere plutot que d'en recopier les champs - une
     * liste a tenir a jour finit toujours par diverger de sa source.
     */
    fun stats(): Map<String, Any?> = engine.advertCapabilities() + mapOf(
        "rawScans" to engine.rawScans,
        "neoScans" to engine.neoScans,
        // ⚠️ **Le temoin du desaccord de version, rendu VISIBLE.**
        //
        // Il etait compte depuis le 2026-08-20 et n'etait expose nulle part :
        // `RSUNA.md` et les notes de release affirmaient pourtant qu'on le
        // voyait au diagnostic. Deux appareils de versions differentes ne se
        // voient pas — c'est voulu — et sans ce compteur rien ne distingue ce
        // cas de « personne autour ». Constate le 2026-08-25, juste avant le
        // premier test a deux appareils.
        "otherVersionScans" to engine.otherVersionScans,
        // ⚠️ **Deux compteurs qui doivent rester visibles meme a zero** : le
        // jour ou ils montent, ils expliquent un ami fantome ou une detection
        // multipliee que rien d'autre n'expliquerait.
        "selfScans" to engine.selfScans,
        "foreignTokenScans" to foreignTokenScans,
        "protocolVersion" to BleConstants.PROTOCOL_VERSION.toInt(),
        // ⚠️ **Le mode d'emission, rendu VISIBLE.** En `cycle`, un ami n'est
        // annonce que 1/N du temps : c'est la premiere chose a regarder quand un
        // croisement se rate sans raison apparente. Et c'est le seul endroit qui
        // dise si le repli s'est declenche - il ne leve rien par ailleurs.
        "advertMode" to if (engine.parallelAdvertising) "parallele" else "cycle",
        // ⚠️ **Repris du disque = amis oui, inconnus non.** Voir [reprisDuDisque].
        "resumedFromDisk" to reprisDuDisque,
        // ⚠️ **L'homme mort de l'identifiant public, rendu VISIBLE.**
        //
        // `publicMuted` a vrai veut dire : le Dart ne donne plus signe de vie,
        // on a cesse de crier l'identifiant public, et l'appareil n'est donc
        // plus decouvrable par des inconnus — alors que le croisement d'amis,
        // lui, continue. Sans cette ligne, ce silence VOULU serait indiscernable
        // d'une panne de radio.
        "publicMuted" to !publicAutorise(),
        "publicHeartbeatAgeMillis" to
            if (dernierBattement == 0L) -1L
            else android.os.SystemClock.elapsedRealtime() - dernierBattement,
        "advertTokensPerSlot" to (schedule?.cycleLength ?: 0),
        "sdk" to android.os.Build.VERSION.SDK_INT,
        "device" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
        // ⚠️ **Le prerequis pre-Android 12, rendu VISIBLE.**
        //
        // Tout ce qui manque sur ce chemin echoue en silence : ni le type de
        // service, ni la permission, ni l'interrupteur de localisation ne
        // levent quoi que ce soit - `startScan` reussit et ne rend jamais rien.
        // Un compteur `neoScans` a zero est alors indiscernable de « personne
        // autour ». Ces trois lignes disent laquelle des trois manque.
        "needsLocation" to (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S),
        "fgsLocationType" to
            ((foregroundTypeUsed and ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION) != 0),
        "locationEnabled" to isLocationEnabled(this),
        // ⚠️ **Les technologies de mesure de distance que l'appareil possede.**
        //
        // Question de Jay, 2026-08-16 : « pour la distance tu as juste utilise
        // le BLE ? ». Oui - c'est la seule radio que TOUS les appareils ont.
        // Mais deux autres donneraient bien mieux si le materiel les portait :
        // l'UWB (~10 cm) et le Wi-Fi RTT (~1-2 m).
        //
        // Plutot que de supposer d'apres le modele, on DEMANDE au systeme. Un
        // « probablement pas » sur une fiche technique ne vaut pas un
        // hasSystemFeature.
        "uwb" to packageManager.hasSystemFeature("android.hardware.uwb"),
        "wifiRtt" to packageManager.hasSystemFeature("android.hardware.wifi.rtt"),
        // ⚠️ **Les deux transports Wi-Fi, sondes ajoutees le 2026-08-17.**
        //
        // Question de Jay : « le Wi-Fi Direct on peut l'utiliser pour les
        // messages ? Peut-etre que cela sera plus fiable que le BLE ? ».
        //
        // `wifiDirect` est present a peu pres partout ; `wifiAware` beaucoup
        // moins, et c'est pourtant LUI le bon candidat (pas de formation de
        // groupe, plusieurs pairs, concu pour le voisinage). Plutot que de
        // supposer d'apres le modele, on DEMANDE au systeme - meme methode que
        // pour l'UWB, ou la supposition aurait ete fausse dans les deux sens.
        "wifiDirect" to packageManager.hasSystemFeature("android.hardware.wifi.direct"),
        "wifiAware" to packageManager.hasSystemFeature("android.hardware.wifi.aware"),
        // ⚠️ `engine.pathStats` (clientPaths / serverPaths / bothPaths) etait
        // fusionne ici. Il comptait les connexions GATT ouvertes par role : plus
        // aucune n'existe depuis le 2026-08-27.
    )

    // ------------------------------------------------------------------
    // Écoute du moteur
    // ------------------------------------------------------------------

    override fun onStatus(status: RadioStatus) {
        lastStatus = status
        bridge?.onStatus(status)
        updateNotification(status)
    }

    override fun onScan(
        address: String,
        advertId: ByteArray,
        rssi: Int,
        txPower: Int,
        type: Byte,
        atMillis: Long,
    ) {
        // ⚠️ **On reconnait TOUJOURS, que le Dart soit la ou non.**
        //
        // C'est le point de tout ce fichier : avant, l'appariement jeton -> ami
        // vivait en Dart, qui meurt avec l'interface. App fermee, l'appareil
        // etait donc **vu sans voir**, et le croisement — fait pour le telephone
        // dans la poche — ne se produisait jamais.
        //
        // Le faire ici ET quand le Dart est present n'est pas une redondance :
        // c'est ce qui evite d'avoir deux comportements selon que l'interface
        // est ouverte ou non. Le Dart deduplique de toute facon par
        // (ami, creneau).
        // ⚠️ **La reconnaissance ne concerne QUE les jetons prives.** Un
        // identifiant public n'est reconnu par personne — c'est son role — et
        // le passer a la table serait lui demander une question qui n'a pas de
        // reponse (consigne de Jay, 2026-08-25 : deux formats, deux chemins).
        val table = if (type == BleConstants.TYPE_FRIEND) recognition else null
        if (table != null) {
            val rang = table.match(advertId, atMillis)
            if (rang != null) {
                sightings.note(
                    NativeSighting(
                        tableId = table.tableId,
                        friendIndex = rang,
                        slot = atMillis / slotMillis,
                        rssi = rssi,
                        txPower = txPower,
                    ),
                )
            } else {
                // Un jeton prive qu'on n'attend pas est celui d'une AUTRE paire.
                foreignTokenScans++
            }
        }

        val target = bridge
        if (target != null) {
            target.onScan(address, advertId, rssi, txPower, type, atMillis)
            return
        }
        pendingScans.add(BufferedScan(address, advertId, rssi, txPower, type, atMillis))
        while (pendingScans.size > scanBufferMax) pendingScans.poll()
    }

    // ⚠️ **`onLink` et `onFrame` ont ete SUPPRIMES le 2026-08-27**, avec le
    // transport BLE. Ils relayaient au Dart la montee d'un lien GATT et les
    // morceaux de trame recus. Le moteur ne les emet plus.

    /**
     * Rejoue l'état courant et les scans mis de côté au pont qui vient
     * d'arriver.
     *
     * Appelé par le pont lui-même : une interface qui vient de naître n'a pas à
     * deviner ce qui s'est passé avant elle.
     */
    fun replayToBridge() {
        replayTo(ProximityBus.listener ?: return)
    }

    private fun replayTo(target: BleEngine.Listener) {
        target.onStatus(lastStatus)
        while (true) {
            val scan = pendingScans.poll() ?: break
            target.onScan(
                scan.address,
                scan.advertId,
                scan.rssi,
                scan.txPower,
                scan.type,
                scan.atMillis,
            )
        }
    }

    // ------------------------------------------------------------------
    // Notification de premier plan
    // ------------------------------------------------------------------

    private fun startForegroundCompat() {
        ensureChannel()
        val notification = buildNotification(lastStatus)
        // ⚠️ La branche `startForeground` sans type a disparu avec le plancher
        // passe de 26 a 29 (2026-08-25) : le type existe depuis l'API 29.
        startForeground(NOTIFICATION_ID, notification, foregroundTypeUsed)
    }

    /**
     * **Le type du service de premier plan, et sur Android 10/11 il decide de
     * tout.**
     *
     * Android ne considere l'app comme « au premier plan » pour la LOCALISATION
     * que si son service de premier plan porte le type `location`. Or avant
     * Android 12, un scan BLE est une operation de localisation : sans ce type,
     * interface fermee, `onScanResult` ne remonte plus rien - **sans erreur, ni
     * exception, ni trace**. C'est exactement le defaut releve le 2026-08-20,
     * qui avait alors conduit a couper Android 10 et 11 (`minSdk = 31`).
     *
     * Avec ce type, `ACCESS_FINE_LOCATION` en « pendant l'utilisation » suffit :
     * `ACCESS_BACKGROUND_LOCATION` ne servirait qu'a DEMARRER un scan sans
     * interface, ce que nous ne faisons jamais (aucun receveur `BOOT_COMPLETED`,
     * le service part toujours de l'ecran Ping).
     *
     * ## ⚠️ Le raisonnement ci-dessus s'est PERIME le 2026-08-26
     *
     * Il portait : *« a partir d'Android 12 on ne le demande pas, se declarer
     * service de localisation sur un appareil recent serait une affirmation
     * fausse »*. C'etait **juste** tant que ce service ne faisait que du BLE :
     * le type `location` ne servait alors qu'a debloquer le scan sous
     * Android 11.
     *
     * **Le ping v2 a change la premisse** : ce service lit desormais une vraie
     * position. Se declarer service de localisation n'est plus une affirmation
     * fausse — c'est devenu **la verite**, et la refuser est ce qui casse.
     *
     * Sans ce type, des que l'app passe en arriere-plan, Android cesse de rendre
     * une position fine. Constate sur l'appareil de Jay le 2026-08-26 :
     * l'incertitude annoncee passe de **129 m a 449 m**, la balise cesse d'etre
     * republiee (**158 s d'age** contre 18 s sur la tablette, qui porte le
     * type), et l'utilisateur **disparait de l'ecran d'en face** trente secondes
     * plus tard. Rien ne le signale.
     *
     * C'est la regle 6 de `CLAUDE.md` : *apres un changement d'architecture,
     * rejouer les decisions qui en dependaient au lieu de derouler un plan ecrit
     * avant.*
     *
     * ⚠️ **A affiner avant la Play Console**, qui exige une justification par
     * type : le service tourne aussi pour le seul croisement d'amis, qui ne lit
     * aucune position. Le declarer alors est plus large que la verite. Le
     * correctif juste serait de **repromouvoir** le service quand le ping public
     * demarre ; il demande un aller-retour de plus. Voir `RAPPELS.md`.
     */
    private val foregroundTypeUsed: Int
        get() = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Proximité",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Détection des membres NeoVibe autour de toi"
                setShowBadge(false)
            },
        )
    }

    /**
     * La notification DIT l'état réel.
     *
     * ⚠️ C'est le prolongement de la règle du moteur : une notification qui
     * annonce « détection active » alors que le Bluetooth est éteint est
     * exactement le mensonge qu'on vient de supprimer côté interface. Elle
     * serait même pire, puisqu'elle est visible en permanence.
     */
    private fun buildNotification(status: RadioStatus): Notification {
        val text = when (status) {
            is RadioStatus.Running ->
                if (status.advertising && status.scanning) "Détection active"
                else if (status.scanning) "Détection active — tu n'es pas annoncé"
                else "En veille — la diffusion a échoué"
            is RadioStatus.AdapterOff -> "En pause — le Bluetooth est éteint"
            // ⚠️ Android 10/11 seulement. Dire « permission manquante » ici
            // enverrait l'utilisateur dans les réglages de l'app, où il ne
            // trouverait rien à corriger : c'est l'interrupteur du système.
            is RadioStatus.LocationOff -> "En pause — localisation éteinte"
            is RadioStatus.PermissionsMissing -> "En pause — permission manquante"
            is RadioStatus.Unsupported -> "Indisponible sur cet appareil"
            is RadioStatus.Failed -> "En pause — ${status.message}"
            is RadioStatus.Starting -> "Démarrage…"
            is RadioStatus.Idle -> "En veille"
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("NeoVibe")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .build()
    }

    private fun updateNotification(status: RadioStatus) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification(status)) }
    }
}
