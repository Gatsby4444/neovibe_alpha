package com.neovibe.neovibe.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanCallback.SCAN_FAILED_ALREADY_STARTED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED
import android.bluetooth.le.ScanCallback.SCAN_FAILED_INTERNAL_ERROR
import android.bluetooth.le.ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES
import android.bluetooth.le.ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Le moteur BLE : advertising, scan, serveur et client GATT.
 *
 * ## Ce qu'il est, et ce qu'il n'est PAS
 *
 * Il possède **le matériel**, rien d'autre. Il ne connaît ni identité, ni
 * chiffrement, ni profil, ni message : il diffuse un identifiant opaque, il
 * rapporte ceux qu'il voit, et il transporte des trames d'octets.
 *
 * ⚠️ **Il ne dépend d'aucune `Activity`** — c'est ce qui lui permet de vivre
 * dans un service et de survivre à la destruction de l'interface (décision de
 * Jay, 2026-08-16). Toute référence à une `Activity` réintroduirait la fragilité
 * qu'on est en train de supprimer.
 *
 * ## Les deux règles qu'il tient, et que l'ancienne couche ne tenait pas
 *
 * 1. **Il ne ment jamais sur son état.** Chaque échec produit un [RadioStatus]
 *    nommé. Il n'existe plus un seul `?: return` silencieux.
 * 2. **Il ne perd jamais un octet.** Les deux sens d'écriture ont leur file.
 */
/** Valeur d'Android quand l'emetteur n'annonce pas sa puissance. */
const val TX_POWER_UNKNOWN = 127

@SuppressLint("MissingPermission") // vérifiées explicitement par evaluateRadio()
class BleEngine(private val context: Context, private val listener: Listener) {

    /** Ce que le moteur remonte. Aucune de ces méthodes ne doit bloquer. */
    interface Listener {
        fun onStatus(status: RadioStatus)
        /**
         * [txPower] est la puissance d'emission annoncee par le pair, en dBm,
         * ou [TX_POWER_UNKNOWN] s'il ne l'annonce pas.
         */
        /**
         * [atMillis] est l'instant ou l'annonce a ete recue.
         *
         * ⚠️ **Il voyage avec l'annonce, il ne se rededuit pas en aval.** Un
         * scan mis de cote pendant que l'interface etait absente est rejoue
         * plus tard : sans sa date, le consommateur le prend pour une
         * observation faite MAINTENANT, et une annonce vieille de plusieurs
         * heures redevient une presence. C'est la couche qui observe qui sait
         * quand ; c'est au consommateur de decider si c'est encore vrai.
         */
        fun onScan(
            address: String,
            advertId: ByteArray,
            rssi: Int,
            txPower: Int,
            type: Byte,
            atMillis: Long,
        )

        /**
         * Le mode d'emission PARALLELE n'a pas pu tenir, il faut revenir au
         * cycle.
         *
         * ⚠️ **Le moteur ne decide pas du repli tout seul** : c'est le service
         * qui detient le plan et l'heure, donc lui seul sait quoi crier ensuite.
         * Le moteur constate et le dit — il ne va pas chercher le plan.
         */
        fun onParallelAdvertLost(reason: String)
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager get() =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var advertising = false
    private var scanning = false

    // ------------------------------------------------------------------
    // Emission PARALLELE — la correction du 2026-08-26
    // ------------------------------------------------------------------
    //
    // ## Ce que le mode CYCLE coutait, et pourquoi ce n'est pas une optimisation
    //
    // Avec plusieurs jetons a crier (un par ami, plus l'identifiant public du
    // ping), le service en emettait **un a la fois** et tournait toutes les
    // 400 ms. Trois consequences, toutes silencieuses :
    //
    // 1. **Un ami n'etait annonce que 1/N du temps.** A dix amis, son jeton
    //    partait 400 ms toutes les 4 secondes — 10 % du temps. Quelqu'un qu'on
    //    croise trois secondes dans un couloir pouvait ne JAMAIS etre vu. Le
    //    croisement devenait probabiliste, et il ratait d'autant plus qu'on a
    //    d'amis : **le mode cycle ne passe pas a l'echelle.**
    // 2. **Chaque rotation retirait puis relancait l'annonce**, et Android tire
    //    une nouvelle adresse aleatoire a chaque demarrage : un seul appareil
    //    apparaissait comme six. (Traite aussi cote Dart, par l'index par jeton.)
    // 3. **Entre le stop et le start, `advertising` valait false**, et l'ecran
    //    affichait « Tu n'es pas annonce » — deux fois et demie par seconde.
    //
    // Ici, chaque jeton a son propre jeu d'annonces, tous emis **en permanence**.
    // Au changement de creneau, on remplace les donnees **sans arreter** le jeu :
    // l'adresse ne change donc pas non plus.
    //
    // ⚠️ **Le repli est le filet, et il doit rester exact.** Le nombre de jeux
    // simultanes depend du controleur et n'est expose par aucune API : on tente,
    // et le premier echec fait revenir au cycle pour tout le monde. Un mode
    // parallele a moitie demarre serait pire que le cycle — certains amis
    // annonces, d'autres pas, sans que rien ne le dise.

    /** Les jeux d'annonces vivants, par rang dans le creneau. */
    private val advertSets = HashMap<Int, AdvertisingSet>()

    /** Les rappels correspondants — `stopAdvertisingSet` exige le meme objet. */
    private val advertSetCallbacks = HashMap<Int, AdvertSetCallback>()

    /** Ce qu'on a demande, pour savoir quand tout est confirme. */
    private var parallelExpected = 0

    /**
     * Jusqu'a quand on s'interdit de retenter le mode parallele.
     *
     * ⚠️ **C'etait un drapeau DEFINITIF jusqu'au 2026-08-28**, et c'etait un
     * defaut : un seul refus — y compris transitoire, pile occupee ou jeu
     * refuse une fois — condamnait l'appareil au mode cycle pour toute la vie
     * du service. Or en cycle, le jeton d'un ami n'est en l'air que 1/N du
     * temps : le defaut d'echelle que le mode parallele existe pour supprimer
     * revenait par la petite porte, et **rien ne le retablissait jamais**.
     *
     * Une interdiction qui ne peut pas s'annuler n'est pas une protection,
     * c'est une panne qui dure. On borne donc dans le temps : un refus reel se
     * re-latche tout seul au bout de [PARALLEL_COOLDOWN_MILLIS] (une tentative
     * ratee toutes les dix minutes ne coute rien), un refus transitoire se
     * repare tout seul.
     */
    private var parallelRefusedUntil = 0L

    /** Vrai quand l'emission tourne en mode parallele. Lu par le diagnostic. */
    var parallelAdvertising = false
        private set

    /**
     * **Ce que la pile a accepte de mettre en l'air**, par opposition a ce
     * qu'on lui a demande. Voir [AdvertOnAir].
     */
    private val onAir = AdvertOnAir()

    /**
     * Le creneau des jetons **reellement** en l'air, `-1` si aucun jeu complet
     * n'est confirme.
     *
     * ⚠️ **Publie dans `stats()`, et c'est la ligne qui manquait le
     * 2026-08-29.** Compare au creneau de l'instant, elle dit d'un coup si
     * l'appareil crie encore le jeton d'il y a une heure — le seul etat dans
     * lequel il est entendu par tous et reconnu par personne.
     */
    val advertSlotOnAir: Long get() = onAir.repereEnLAir

    /** Contenus d'annonce refuses par la pile. Voir [AdvertOnAir.refus]. */
    val advertDataRefus: Int get() = onAir.refus

    /**
     * Rappels arrives pour un jeu d'annonces **deja remplace**.
     *
     * ⚠️ **Doit rester visible meme a zero.** Ce compteur existe parce que la
     * course qu'il mesure a ete trouvee **a la relecture, pas sur appareil** :
     * tant qu'il vaut zero, elle est theorique ; le jour ou il monte, il
     * explique d'un coup un `advertSetsOnAir` qui sous-compte et un
     * `advertSlotDrift` bloque sur -1. Voir `AdvertSetCallback.estLeCourant`.
     */
    var advertStaleCallbacks = 0
        private set

    /**
     * L'ID que l'on DOIT diffuser tant qu'on est censé être visible.
     *
     * C'est la mémoire du moteur : elle survit à une coupure de Bluetooth, et
     * c'est elle qui permet de repartir tout seul quand l'adaptateur revient —
     * sans que l'utilisateur ait à toucher quoi que ce soit.
     */
    private var desiredAdvertId: ByteArray? = null
    private var desiredAdvertType: Byte = BleConstants.TYPE_PUBLIC

    /** Annonces NeoVibe ecartees parce qu'elles parlaient une autre version. */
    var otherVersionScans = 0
        private set

    /**
     * Nos PROPRES annonces, captees et ecartees.
     *
     * ⚠️ **Ce compteur doit rester visible meme s'il vaut toujours zero** : le
     * jour ou il monte, il explique un ami fantome que rien d'autre n'explique.
     */
    var selfScans = 0
        private set

    // ⚠️ **`foreignTokenScans` a ete RETIRE d'ici le 2026-08-28.** Il etait
    // declare, publie dans `stats()`... et **jamais incremente** : le rapport de
    // diagnostic affichait donc un zero permanent presente comme une mesure.
    //
    // Ce moteur ne peut pas le compter : il ne detient pas la table de
    // reconnaissance, donc il ne sait pas distinguer « jeton d'ami qui ne
    // m'est pas destine » de « jeton d'ami que j'attends ». Celui qui le sait,
    // c'est `ProximityService`, qui interroge la table — c'est la que le
    // compteur vit desormais.

    /**
     * Ce que la radio sait faire en matiere d'annonces simultanees.
     *
     * ⚠️ **On DEMANDE au systeme, on ne deduit pas du modele** - meme
     * raisonnement que pour l'UWB et le Wi-Fi RTT. C'est ce qui permet a
     * l'architecture de s'adapter a l'appareil (consigne de Jay, 2026-08-20)
     * plutot que de supposer le pire partout.
     */
    fun advertCapabilities(): Map<String, Any?> {
        val a = adapter
        return mapOf(
            "multipleAdvertisement" to (a?.isMultipleAdvertisementSupported ?: false),
            "extendedAdvertising" to
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    (a?.isLeExtendedAdvertisingSupported ?: false)),
            "maxAdvertisingDataLength" to
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    a?.leMaximumAdvertisingDataLength ?: 31
                } else {
                    31
                },
            "periodicAdvertising" to
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    (a?.isLePeriodicAdvertisingSupported ?: false)),
        )
    }

    private var lastPublished: RadioStatus? = null

    /**
     * Annonces BLE recues, **toutes applications confondues**.
     *
     * ⚠️ C'est l'instrument qui manquait. Avec le seul etat « detection
     * active », deux pannes tres differentes se ressemblaient :
     *
     * - `rawScans == 0` → la radio ne livre **rien**. Le probleme est sous nous
     *   (permission, puce, bridage systeme) ;
     * - `rawScans > 0` mais `neoScans == 0` → la radio livre, mais **aucune
     *   annonce NeoVibe n'arrive**. Le probleme est chez celui d'en face, ou
     *   dans le contenu de son annonce.
     *
     * Un seul chiffre separe donc « je n'entends rien » de « personne ne
     * parle » — deux phrases que l'ancienne interface confondait.
     */
    @Volatile
    var rawScans = 0
        private set

    /** Parmi elles, celles qui portent notre signature. */
    @Volatile
    var neoScans = 0
        private set

    // ⚠️ **`pathStats`, `bothPathsPeak` et `notePaths` ont ete SUPPRIMES le
    // 2026-08-27**, avec les connexions GATT qu'ils comptaient.
    //
    // Ils mesuraient une hypothese : une meme adresse peut-elle porter DEUX
    // connexions a la fois, une par role ? Ils ont fait leur travail — a zero
    // sur les deux appareils de Jay, ils ont **refute** l'hypothese et evite une
    // reecriture du natif fondee sur une deduction. Un instrument qui ne peut
    // plus rien mesurer se retire avec ce qu'il mesurait.

    // ------------------------------------------------------------------
    // Cycle de vie
    // ------------------------------------------------------------------

    fun attach() {
        context.registerReceiver(
            adapterWatcher,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
        )
        publish(currentStatus())
    }

    fun detach() {
        try {
            context.unregisterReceiver(adapterWatcher)
        } catch (_: IllegalArgumentException) {
            // Jamais enregistré : rien à faire.
        }
        stop()
    }

    /**
     * Demande à être visible et à détecter, avec [advertId].
     *
     * Rend `true` si le matériel a démarré. Sinon l'appelant n'a **rien** à
     * déduire : le [RadioStatus] publié dit exactement pourquoi.
     *
     * ⚠️ L'intention est mémorisée **même en cas d'échec** : si le Bluetooth est
     * éteint, on veut repartir dès qu'il revient. C'est le cœur de la
     * résistance aux aléas.
     */
    /**
     * [type] n'est pas `TYPE_PUBLIC` dans un seul cas : la **reprise depuis le
     * disque**, ou il n'y a pas d'identifiant public a crier et ou le premier
     * jeton disponible est celui d'un ami. Le poser juste evite d'annoncer
     * quelques millisecondes un jeton prive sous une etiquette publique — que
     * les autres appareils prendraient pour un inconnu.
     */
    fun start(advertId: ByteArray, type: Byte = BleConstants.TYPE_PUBLIC): Boolean {
        desiredAdvertId = advertId
        desiredAdvertType = type
        scanRetried = false
        // 🔴 **TOUS LES COMPTEURS, OU AUCUN — corrige le 2026-08-31.**
        //
        // Seuls `rawScans` et `neoScans` repartaient de zero ici. Les quatre
        // autres couraient depuis la creation du moteur — et `start()` est
        // rappele automatiquement 1,2 s apres chaque rallumage du Bluetooth.
        //
        // Les huit chiffres sont ensuite affiches cote a cote dans le meme
        // rapport, comme s'ils couvraient la meme periode. Un `neoScans = 0`
        // avec `otherVersionScans = 500` se lisait « la radio n'entend rien
        // mais a entendu 500 annonces d'une autre version » — alors que les 500
        // pouvaient dater d'avant le dernier redemarrage.
        //
        // ⚠️ Un instrument dont les graduations n'ont pas la meme origine ne
        // mesure pas, il suggere.
        rawScans = 0
        neoScans = 0
        selfScans = 0
        otherVersionScans = 0
        advertStaleCallbacks = 0
        onAir.reinitialiseRefus()
        // ⚠️ **Une session neuve reessaie le parallele.** Le repli est une
        // constatation sur un instant, pas une propriete de l'appareil : le
        // reconduire sans le retester, c'est transformer un incident en
        // limitation permanente.
        parallelRefusedUntil = 0L
        val blocker = evaluateRadio(context)
        if (blocker != null) {
            publish(blocker)
            return false
        }
        publish(RadioStatus.Starting)
        return try {
            rememberOwnToken(advertId)
            startAdvertising(advertId, desiredAdvertType)
            startScanning()
            publish(currentStatus())
            true
        } catch (e: Exception) {
            publish(RadioStatus.Failed("start", e.message ?: e.toString()))
            false
        }
    }

    /** Arrêt VOULU : l'intention disparaît, on ne repartira pas tout seul. */
    fun stop() {
        desiredAdvertId = null
        teardown()
        publish(currentStatus())
    }

    /**
     * Cesse d'annoncer, sans arreter le scan.
     *
     * Utilise quand le plan d'emission est epuise : on prefere le silence a un
     * jeton perime, qui serait indiscernable d'un fonctionnement normal tout en
     * ne se faisant reconnaitre par personne.
     */
    fun pauseAdvertising() {
        // 🔴 **LE SILENCE DOIT ETRE TOTAL — corrige le 2026-08-29.**
        //
        // Cette methode n'arretait que l'annonceur LEGACY. En mode parallele,
        // les jeux d'annonces continuaient donc de crier apres un « on se
        // tait » : plan epuise, ou identifiant public devenu intraduisible
        // (l'homme mort du meme jour). **La fonction faisait l'inverse de son
        // nom, sans rien lever.**
        //
        // ⚠️ Deux facons d'etre en l'air, un seul ordre pour se taire : les
        // deux doivent s'arreter ici, sinon « se taire » veut dire deux choses
        // selon le mode courant.
        stopParallelAdverts()
        stopAdvertising()
        publish(currentStatus())
    }

    /**
     * Combien de jeux d'annonces on accepte de tenter simultanement.
     *
     * ⚠️ **Une borne RAISONNEE, pas mesuree** (2026-08-26). Les controleurs
     * BLE courants tiennent 4 a 8 jeux ; aucune API ne le dit. Au-dela, on ne
     * tente meme pas : quelqu'un qui a vingt amis aurait vingt jeux, le
     * controleur refuserait, et on aurait paye une bascule pour rien. C'est la
     * premiere valeur a confronter au terrain.
     */
    private val maxParallelSets = 6

    /**
     * Peut-on esperer emettre [count] jetons en meme temps ?
     *
     * ⚠️ **On demande a l'adaptateur, on ne deduit pas du modele** - meme
     * raisonnement que [advertCapabilities].
     */
    private fun parallelPossible(count: Int): Boolean =
        System.currentTimeMillis() >= parallelRefusedUntil &&
            count in 2..maxParallelSets &&
            (adapter?.isMultipleAdvertisementSupported == true)

    /** Le contenu d'une annonce. **Un seul endroit le compose.** */
    private fun advertDataFor(advertId: ByteArray, type: Byte): AdvertiseData =
        AdvertiseData.Builder()
            .addManufacturerData(
                BleConstants.MANUFACTURER_ID,
                BleConstants.MAGIC +
                    byteArrayOf(BleConstants.PROTOCOL_VERSION, type) +
                    advertId,
            )
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(true)
            .build()

    /**
     * Depose ce qu'il faut crier pour le creneau courant, **tout en meme
     * temps**.
     *
     * Rend `false` si l'appelant doit se rabattre sur le cycle.
     *
     * ⚠️ **Met a jour SANS redemarrer quand c'est possible.** Un jeu qu'on
     * arrete et relance repart avec une nouvelle adresse aleatoire - c'est
     * exactement ce qu'on cherche a supprimer. `setAdvertisingData` remplace le
     * contenu et laisse l'adresse tranquille.
     *
     * ## 🔴 Et il ne REECRIT que ce qui a change — 2026-08-29
     *
     * Ce corps reecrivait les deux jeux **a chaque tour**, soit toutes les
     * trente secondes (`ProximityService.nextDelay`), pour un contenu qui ne
     * change que tous les quarts d'heure. Environ 2 900 ecrits inutiles par
     * appareil et par nuit, chacun une occasion pour la pile de refuser — et un
     * refus etait invisible (voir [AdvertOnAir]).
     *
     * [repere] : le creneau des jetons deposes. Il ne sert pas ici ; il permet
     * au diagnostic de dire **de quand date ce qui rayonne vraiment**.
     */
    fun applyAdverts(ids: List<ByteArray>, types: ByteArray, repere: Long): Boolean {
        if (evaluateRadio(context) != null) return false
        ids.forEach { rememberOwnToken(it) }
        if (!parallelPossible(ids.size)) return false

        if (parallelAdvertising && advertSets.size == ids.size) {
            onAir.noteDemande(ids.map { AdvertOnAir.hex(it) }, repere)
            for ((index, id) in ids.withIndex()) {
                val jeton = AdvertOnAir.hex(id)
                if (!onAir.besoinDEcrire(index, jeton)) continue
                val set = advertSets[index] ?: return startParallelAdverts(ids, types, repere)
                val type = types.getOrElse(index) { BleConstants.TYPE_PUBLIC }
                try {
                    onAir.noteEcrit(index, jeton)
                    set.setAdvertisingData(advertDataFor(id, type))
                } catch (e: Exception) {
                    fallbackFromParallel("mise a jour refusee : " + e.message)
                    return false
                }
            }
            return true
        }
        return startParallelAdverts(ids, types, repere)
    }

    private fun startParallelAdverts(
        ids: List<ByteArray>,
        types: ByteArray,
        repere: Long,
    ): Boolean {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return false
        stopAdvertising()
        stopParallelAdverts()

        val params = AdvertisingSetParameters.Builder()
            // ⚠️ **Mode LEGACY, delibere.** Une annonce etendue n'est pas vue
            // par un scan legacy - et notre scan l'est, comme celui de tout
            // appareil qui ne demande pas explicitement l'inverse. Passer en
            // etendu nous rendrait invisibles d'une partie du parc **sans lever
            // la moindre erreur**. Nos 20 octets tiennent largement dans les 31
            // du format legacy.
            .setLegacyMode(true)
            // En legacy, connectable implique scannable : Android leve un
            // IllegalArgumentException si les deux ne s'accordent pas.
            .setConnectable(true)
            .setScannable(true)
            .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
            .build()

        parallelExpected = ids.size
        advertSets.clear()
        advertSetCallbacks.clear()
        // ⚠️ **Un demarrage porte deja les donnees.** On les declare « en vol »
        // ici, et `onAdvertisingSetStarted` les confirmera : sans ca, le premier
        // creneau apres un demarrage n'aurait jamais de repere, et le
        // diagnostic dirait « on ne sait pas » pour un cas parfaitement sain.
        onAir.noteDemande(ids.map { AdvertOnAir.hex(it) }, repere)
        for ((index, id) in ids.withIndex()) {
            val callback = AdvertSetCallback(index)
            advertSetCallbacks[index] = callback
            try {
                onAir.noteEcrit(index, AdvertOnAir.hex(id))
                advertiser.startAdvertisingSet(
                    params,
                    advertDataFor(id, types.getOrElse(index) { BleConstants.TYPE_PUBLIC }),
                    null,
                    null,
                    null,
                    callback,
                )
            } catch (e: Exception) {
                // Un refus immediat (argument invalide, pile occupee) n'attend
                // pas le rappel : on replie tout de suite plutot que de rester
                // a moitie demarre.
                fallbackFromParallel("demarrage refuse : " + e.message)
                return false
            }
        }
        return true
    }

    /**
     * Combien de jeux d'annonces sont **reellement en l'air** en ce moment.
     *
     * ⚠️ **Publie dans `stats()`, et ce n'est pas decoratif.** Le defaut du
     * 2026-08-29 se lisait exactement la : `advertMode = cycle` **et** deux jeux
     * paralleles encore actifs — une contradiction que rien n'affichait. Un
     * mode d'emission ne se constate pas par le drapeau qu'on a pose, mais en
     * comptant ce qui emet.
     */
    val advertSetsOnAir: Int get() = advertSets.size

    /**
     * Le plafond de jeux d'annonces simultanes, et le temps restant avant de
     * pouvoir retenter le parallele.
     *
     * ## 🔴 Pourquoi ces deux chiffres sont publies — 2026-08-31
     *
     * `advertMode` dit « cycle », ce qui est vrai, et ne dit pas POURQUOI. Or
     * il y a deux raisons tres differentes de s'y trouver, et elles ne se
     * corrigent pas de la meme facon :
     *
     * | Ce qu'on lit | Ce que ca veut dire |
     * |---|---|
     * | `advertTokensPerSlot > advertMaxSets` | **le plafond**, atteint des 6 jetons — donc des 5 amis avec la decouverte allumee |
     * | `advertParallelCooldownMs > 0` | **un refus** de la pile, qu'on retentera tout seul |
     *
     * ⚠️ **Le premier cas ramene le defaut d'echelle que le mode parallele
     * existe pour supprimer** : en cycle, le jeton d'un ami n'est en l'air que
     * 1/N du temps. Il ne levait rien et ne se comptait nulle part — on ne
     * pouvait donc pas savoir, en lisant un rapport, si un croisement rate
     * venait de la ou d'ailleurs.
     *
     * ⚠️ **On publie des FAITS, pas un verdict.** `maxParallelSets` reste une
     * valeur raisonnee et non mesuree : la monter sans releve sur appareil ne
     * ferait que deplacer la supposition. Ces deux lignes disent ou elle mord.
     */
    val advertMaxSets: Int get() = maxParallelSets

    val advertParallelCooldownMs: Long
        get() = (parallelRefusedUntil - System.currentTimeMillis()).coerceAtLeast(0L)

    /** Arrete tous les jeux, sans rien dire a personne. */
    private fun stopParallelAdverts() {
        val advertiser = adapter?.bluetoothLeAdvertiser
        advertSetCallbacks.values.forEach { cb ->
            runCatching { advertiser?.stopAdvertisingSet(cb) }
        }
        advertSets.clear()
        advertSetCallbacks.clear()
        parallelExpected = 0
        parallelAdvertising = false
        // ⚠️ **Plus rien n'est en l'air : il faut le DIRE.** Garder le dernier
        // repere ferait lire « a jour » a un diagnostic pris pendant un
        // silence — exactement le genre de zero impose par la forme de
        // l'instrument plutot que mesure.
        onAir.oublie()
    }

    /**
     * Le parallele n'a pas tenu : on defait tout et on le DIT.
     *
     * ⚠️ **Tout ou rien.** Garder les jeux qui ont demarre laisserait certains
     * amis annonces et d'autres muets, sans qu'aucun compteur ne le montre.
     */
    private fun fallbackFromParallel(reason: String) {
        val dejaReplie = System.currentTimeMillis() < parallelRefusedUntil
        if (dejaReplie && !parallelAdvertising && advertSets.isEmpty()) return
        parallelRefusedUntil = System.currentTimeMillis() + PARALLEL_COOLDOWN_MILLIS
        stopParallelAdverts()
        advertising = false
        main.post { listener.onParallelAdvertLost(reason) }
    }

    /** Un jeu d'annonces, et son rang dans le creneau. */
    private inner class AdvertSetCallback(private val index: Int) : AdvertisingSetCallback() {

        /**
         * Ce rappel est-il encore celui du jeu [index] ?
         *
         * ## 🔴 La course que cette question supprime — relevee le 2026-08-29
         *
         * `stopAdvertisingSet` ne s'execute pas tout de suite : la pile rappelle
         * `onAdvertisingSetStopped` **plus tard**. Or [stopParallelAdverts] vide
         * `advertSetCallbacks` et [startParallelAdverts] enregistre aussitot de
         * NOUVEAUX rappels **aux memes rangs**.
         *
         * Un rappel de l'ancien plan arrivant apres coup faisait donc
         * `advertSets.remove(0)` — c'est-a-dire **retirait le jeu neuf** — et
         * effacait l'etat de [AdvertOnAir] fraichement pose. Consequences :
         * `advertSetsOnAir` sous-compte, la voie rapide de [applyAdverts] ne
         * s'applique plus, et `advertSlotDrift` retombe a « on ne sait pas ».
         *
         * ⚠️ **Deux objets au meme rang, c'est le plus ancien qui gagne en
         * silence** — la regle 2 de `CLAUDE.md`, appliquee a des rappels.
         *
         * ⚠️ **Non reproduit sur appareil, trouve a la relecture.** D'ou le
         * compteur [advertStaleCallbacks] : si la course existe vraiment, elle
         * se lira au diagnostic au lieu de se deviner.
         */
        private fun estLeCourant(): Boolean = advertSetCallbacks[index] === this

        override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
            if (!estLeCourant()) {
                advertStaleCallbacks++
                // ⚠️ **Un jeu d'un plan abandonne qui demarre quand meme doit
                // etre RACCROCHE.** Le laisser en l'air, c'est exactement le
                // defaut du 2026-08-29 matin : un ancien plan qui continue de
                // crier pendant qu'on en annonce un nouveau.
                if (status == ADVERTISE_SUCCESS && set != null) {
                    runCatching {
                        adapter?.bluetoothLeAdvertiser?.stopAdvertisingSet(this)
                    }
                }
                return
            }
            if (status != ADVERTISE_SUCCESS || set == null) {
                fallbackFromParallel("jeu " + index + " refuse (code " + status + ")")
                return
            }
            advertSets[index] = set
            onAir.noteConfirme(index)
            if (parallelExpected > 0 && advertSets.size >= parallelExpected) {
                parallelAdvertising = true
                advertising = true
                publish(currentStatus())
            }
        }

        /**
         * 🔴 **LE RAPPEL QUI MANQUAIT — ecrit le 2026-08-29.**
         *
         * `setAdvertisingData` est asynchrone : elle ne rend rien et ne leve
         * rien, et c'est **ici** que la pile dit oui ou non. Sans cette
         * methode, un refus ne se voyait nulle part — le jeu continuait de
         * rayonner le jeton du creneau precedent pendant que tous les
         * compteurs de l'emetteur disaient que tout allait bien.
         *
         * ⚠️ **On ne repare rien ici, on constate.** Le tour suivant reecrira
         * de lui-meme, parce que [AdvertOnAir.besoinDEcrire] redevient vrai
         * pour un jeu dont on ne sait plus ce qu'il porte. Un refus qui
         * persiste se lit alors au diagnostic — `advertDataRefus` monte et
         * `advertSlotOnAir` decroche — au lieu de se deviner.
         */
        override fun onAdvertisingDataSet(set: AdvertisingSet?, status: Int) {
            if (!estLeCourant()) {
                advertStaleCallbacks++
                return
            }
            if (status == ADVERTISE_SUCCESS) onAir.noteConfirme(index)
            else onAir.noteRefus(index)
        }

        /**
         * ⚠️ **Seul un arret NON demande passe ici.** Quand c'est nous qui
         * arretons, [stopParallelAdverts] a deja vide `advertSets` et
         * [AdvertOnAir] de facon synchrone, et retire ce rappel du catalogue :
         * il n'est donc plus le courant, et il ne touche a rien. Ce qui reste
         * est le seul cas interessant — **la pile a coupe un jeu toute seule**.
         */
        override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
            if (!estLeCourant()) {
                advertStaleCallbacks++
                return
            }
            advertSets.remove(index)
            onAir.oublie()
        }
    }

    fun updateAdvert(advertId: ByteArray, type: Byte, repere: Long) {
        desiredAdvertId = advertId
        desiredAdvertType = type
        rememberOwnToken(advertId)
        if (evaluateRadio(context) != null) return
        // 🔴 **PRENDRE L'AIR EN CYCLE, C'EST LIBERER LE PARALLELE —
        // corrige le 2026-08-29, sur un defaut releve par Jay a deux appareils.**
        //
        // Ce qu'il a observe : il eteint « Croiser mes amis » sur son telephone,
        // son ecran cesse d'afficher mimi — et la tablette de mimi **continue de
        // le voir, distance a jour**. Couper le ping puis le rallumer le faisait
        // disparaitre.
        //
        // La cause : le plan passait de DEUX jetons (public + ami) a UN. Or
        // `applyAdverts` refuse le parallele en dessous de deux jetons
        // (`parallelPossible`) et **rendait `false` sans arreter les jeux deja
        // en l'air**. On repliait donc en cycle, on demarrait une annonce
        // legacy... par-dessus deux jeux paralleles toujours actifs, dont celui
        // qui portait le jeton d'ami.
        //
        // ⚠️ **L'ancien plan restait donc en l'air indefiniment**, alors que
        // tout, du Dart au natif, avait correctement depose le nouveau. Aucun
        // compteur ne le montrait : `advertMode` disait « cycle », ce qui etait
        // vrai, et ne disait pas que le parallele n'avait pas ete raccroche.
        //
        // ⚠️ **Corrige ICI plutot que dans le `return false`** : ce qui compte
        // n'est pas de rattraper un refus particulier, c'est qu'a la sortie de
        // `emitNext` **un seul mode soit en l'air**. Les trois portes de sortie
        // (parallele, cycle, silence) l'imposent maintenant chacune.
        stopParallelAdverts()
        stopAdvertising()
        // ⚠️ **Le cycle aussi doit dire de quand date ce qu'il crie.** Les deux
        // modes repondent a la meme question au diagnostic ; n'instrumenter que
        // le parallele aurait fait lire « on ne sait pas » comme « c'est
        // casse » sur les appareils qui se replient.
        onAir.noteDemande(listOf(AdvertOnAir.hex(advertId)), repere)
        onAir.noteEcrit(0, AdvertOnAir.hex(advertId))
        startAdvertising(advertId, type)
        // ⚠️ **On ne publie PAS ici, et c'est la correction du 2026-08-26.**
        //
        // `stopAdvertising()` pose `advertising = false` ; `startAdvertising()`
        // ne le repose qu'au rappel `onStartSuccess`, plus tard. Publier entre
        // les deux annoncait donc un `Running(advertising = false)` — que
        // l'ecran affiche « Tu n'es pas annonce » — pour un redemarrage que
        // NOUS venions de provoquer. En mode cycle, c'etait deux fois et demie
        // par seconde : Jay a vu le bandeau clignoter en permanence.
        //
        // Un etat transitoire qu'on a soi-meme cause n'est pas un fait sur la
        // radio. Les rappels, eux, publient le resultat — et un vrai refus du
        // systeme reste donc parfaitement visible.
    }

    /**
     * **Ce que nous crions nous-memes, pour ne pas nous reconnaitre nous-memes.**
     *
     * Un appareil peut capter sa propre annonce — par reflexion, par un relais,
     * ou parce que sa puce la lui remonte. C'est ce qui affichait « mimi tout
     * pres » alors que le telephone de mimi etait eteint (2026-08-25).
     *
     * ⚠️ **Ce filtre n'est exact que depuis le protocole 5** (2026-08-26). En
     * version 4 le jeton d'ami etait **symetrique** : celui que nous emettions
     * pour un ami etait exactement celui que nous attendions de lui, et ce
     * filtre jetait donc **toutes** ses annonces — la moitie du trafic radio,
     * comptee en `selfScans`, sans qu'aucune erreur ne soit levee. La cause a
     * ete supprimee en amont : le jeton porte desormais le nom de son emetteur
     * (`ProximityIdentity.pairToken`), donc « le mien » et « le sien » sont
     * deux valeurs differentes.
     *
     * Borne a [OWN_TOKENS_MAX] : un plan couvre plusieurs heures et plusieurs
     * amis, on ne garde que ce qui vient d'etre crie.
     */
    private val ownTokens = LinkedHashSet<String>()

    private companion object {
        const val OWN_TOKENS_MAX = 64

        /** Combien de temps on s'interdit de retenter le mode parallele. */
        const val PARALLEL_COOLDOWN_MILLIS = 10 * 60 * 1000L
    }

    private fun rememberOwnToken(token: ByteArray) {
        ownTokens.add(token.joinToString("") { "%02x".format(it) })
        while (ownTokens.size > OWN_TOKENS_MAX) {
            ownTokens.remove(ownTokens.first())
        }
    }

    private fun isOwnToken(token: ByteArray): Boolean =
        ownTokens.contains(token.joinToString("") { "%02x".format(it) })

    /** Coupe le matériel sans toucher à l'intention (Bluetooth qui s'éteint). */
    private fun teardown() {
        stopAdvertising()
        // ⚠️ **Les jeux paralleles aussi.** Les oublier ici, c'est laisser la
        // radio annoncer apres l'extinction du Bluetooth — et c'est exactement
        // la famille « X nettoye, Y oublie » que ce fichier existe pour eviter.
        stopParallelAdverts()
        stopScanning()
    }

    private fun currentStatus(): RadioStatus {
        val blocker = evaluateRadio(context)
        if (blocker != null) return blocker
        if (desiredAdvertId == null) return RadioStatus.Idle
        return RadioStatus.Running(advertising, scanning)
    }

    private fun publish(status: RadioStatus) {
        if (status == lastPublished) return
        lastPublished = status
        main.post { listener.onStatus(status) }
    }

    /**
     * L'adaptateur qui s'éteint ou se rallume.
     *
     * ⚠️ **C'est la pièce qui manquait entièrement.** Sans elle, rallumer le
     * Bluetooth ne relançait rien : `start()` avait déjà « réussi », il n'était
     * jamais rappelé, et il fallait couper puis remettre l'interrupteur de
     * visibilité dans l'app — ce que personne ne devine.
     */
    private val adapterWatcher = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> {
                    val wanted = desiredAdvertId
                    if (wanted == null) {
                        publish(currentStatus())
                        return
                    }
                    // PAS TOUT DE SUITE. STATE_ON annonce que l'adaptateur est
                    // allume, pas que la pile BLE accepte deja un scan :
                    // demarrer dans la foulee echoue souvent en erreur interne,
                    // et on aurait alors accuse le code d'un defaut qui n'est
                    // qu'un defaut de rythme.
                    publish(RadioStatus.Starting)
                    main.postDelayed({ if (desiredAdvertId != null) start(wanted) }, 1_200)
                }
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                    // ⚠️ Il fallait aussi annoncer au Dart la mort de chaque lien
                    // GATT, sans quoi le haut croyait qu'ils tenaient encore.
                    // Plus aucun lien n'existe depuis le 2026-08-27 : couper la
                    // radio suffit, et la presence expire d'elle-meme.
                    teardown()
                    publish(currentStatus())
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Advertising et scan
    // ------------------------------------------------------------------

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertising = true
            onAir.noteConfirme(0)
            publish(currentStatus())
        }

        override fun onStartFailure(errorCode: Int) {
            advertising = false
            onAir.noteRefus(0)
            // L'advertising peut échouer SEUL (trop d'annonceurs, pile occupée)
            // sans emporter le scan : on reste donc en Running, avec
            // `advertising = false`. C'est visible, et c'est vrai.
            publish(
                if (scanning) currentStatus()
                else RadioStatus.Failed("advertise", advertiseFailureText(errorCode)),
            )
        }
    }

    private fun advertiseFailureText(code: Int): String = when (code) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE ->
            "L'annonce est trop grosse pour cet appareil."
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS ->
            "Trop d'applications diffusent en meme temps sur cet appareil."
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED ->
            "Une diffusion precedente n'a pas pu etre arretee."
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR ->
            "Le Bluetooth de l'appareil a rencontre une erreur interne."
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED ->
            "Cet appareil ne sait pas se rendre visible en Bluetooth basse " +
                "consommation."
        else -> "La diffusion a echoue (code Android $code)."
    }

    private fun startAdvertising(advertId: ByteArray, type: Byte) {
        if (advertising) return
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            publish(RadioStatus.Failed("advertise", "Advertising indisponible sur cet appareil"))
            return
        }
        // ⚠️ **Le contenu vient de `advertDataFor`, et de nulle part ailleurs.**
        // Il etait compose ici ET dans le mode parallele : deux copies du
        // format d'annonce, donc deux versions du protocole le jour ou l'une
        // des deux change. La note sur la puissance d'emission y a suivi.
        val data = advertDataFor(advertId, type)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true) // connectable : le chat passe par le GATT
            .setTimeout(0)
            .build()
        advertiser.startAdvertising(settings, data, advertiseCallback)
        // `advertising` n'est PAS posé ici : il l'est dans onStartSuccess.
        // L'ancienne couche le posait tout de suite — donc elle annonçait
        // « ça diffuse » avant de savoir si ça diffusait.
    }

    private fun stopAdvertising() {
        if (!advertising) return
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        advertising = false
        // Meme raison que dans [stopParallelAdverts] : ce qui ne rayonne plus ne
        // doit pas continuer d'etre compte comme a jour.
        onAir.oublie()
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            // Compte AVANT tout tri : c'est ce chiffre qui dit si la radio
            // livre quelque chose, independamment de ce qu'on en garde.
            rawScans++
            val payload = result.scanRecord
                ?.getManufacturerSpecificData(BleConstants.MANUFACTURER_ID) ?: return
            if (payload.size != BleConstants.ADVERT_PAYLOAD_SIZE) return
            if (payload[0] != BleConstants.MAGIC[0] || payload[1] != BleConstants.MAGIC[1]) return
            neoScans++
            // ⚠️ **Une version differente se COMPTE, elle ne disparait pas.**
            //
            // Sans cet octet, deux versions qui ne se comprennent pas ne se
            // voient simplement pas - sans erreur, sans trace, et sans que
            // personne puisse diagnostiquer autre chose qu'« il ne me voit
            // pas ». Ici, l'annonce est ecartee mais l'ecart est visible au
            // diagnostic.
            if (payload[2] != BleConstants.PROTOCOL_VERSION) {
                otherVersionScans++
                return
            }
            // ⚠️ **Le TYPE d'abord : public et prive ne suivent pas le meme
            // chemin.** Consigne de Jay du 2026-08-25. Un jeton prive qui ne
            // nous est pas destine n'est pas un inconnu — c'est le jeton d'un
            // autre, et il se jette. Le confondre avec une decouverte, c'est
            // exactement ce qui affichait « 13 detections » pour un appareil.
            val type = payload[3]
            val id = payload.copyOfRange(4, BleConstants.ADVERT_PAYLOAD_SIZE)

            // ⚠️ **Notre propre annonce**, captee par reflexion, par un relais,
            // ou parce que la puce nous la remonte. Sans ce filtre, elle
            // ressortirait comme une detection.
            //
            // ⚠️ **Le commentaire qui vivait ici disait « le jeton d'ami est
            // symetrique » — c'etait faux depuis le 2026-08-26**, et la
            // documentation de [ownTokens], deux cents lignes plus haut dans ce
            // meme fichier, expliquait justement que la symetrie avait ete
            // supprimee. Deux commentaires du meme fichier se contredisaient ;
            // corrige le 2026-08-31.
            //
            // La difference compte : quand le jeton etait symetrique, ce filtre
            // jetait TOUTES les annonces de l'ami (une sur deux du trafic).
            // Depuis que le jeton porte le nom de son emetteur
            // (`ProximityIdentity.pairToken`), « le mien » et « le sien » sont
            // deux valeurs differentes, et le filtre est exact.
            if (isOwnToken(id)) {
                selfScans++
                return
            }
            // `txPower` vaut TX_POWER_NOT_PRESENT (127) si l'emetteur ne
            // l'annonce pas - un appareil sur une version anterieure, par
            // exemple. On transmet tel quel : c'est au-dessus de decider quoi
            // en faire, et inventer une valeur par defaut ici la rendrait
            // indiscernable d'une vraie mesure.
            val tx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                result.txPower
            } else {
                TX_POWER_UNKNOWN
            }
            // ⚠️ **La date est relevee ICI**, au moment de la reception, et non
            // au moment ou le consommateur la traite : entre les deux il peut
            // s'ecouler des heures si l'interface est absente.
            val recuA = System.currentTimeMillis()
            main.post {
                listener.onScan(result.device.address, id, result.rssi, tx, type, recuA)
            }
        }

        /**
         * Un code d'erreur brut n'est PAS un message.
         *
         * La premiere version publiait « Scan impossible (6) ». Jay l'a lu au
         * test et n'a rien pu en faire - c'est le contraire de ce que ce
         * chantier cherche : nommer une cause ACTIONNABLE. Deux de ces six cas
         * se reparent d'ailleurs tout seuls, encore fallait-il les distinguer.
         */
        override fun onScanFailed(errorCode: Int) {
            scanning = false
            when (errorCode) {
                SCAN_FAILED_ALREADY_STARTED -> {
                    // Un scan de NOTRE application est encore enregistre cote
                    // systeme : typiquement apres une coupure du Bluetooth, ou
                    // stopScan n'a pas pu s'executer (le scanner etait deja
                    // null). On degage la place et on reprend, une seule fois.
                    dropScanRegistration()
                    if (retryScan()) return
                }
                SCAN_FAILED_SCANNING_TOO_FREQUENTLY -> {
                    // Android limite un meme processus a quelques demarrages de
                    // scan par tranche de 30 s. Ce n'est pas une panne, c'est
                    // une attente : on le DIT, et on repart tout seul.
                    publish(
                        RadioStatus.Failed(
                            "scanThrottled",
                            "Android a mis la detection en pause : trop de " +
                                "demarrages en peu de temps. Reprise automatique " +
                                "dans une trentaine de secondes.",
                        ),
                    )
                    main.postDelayed({ if (desiredAdvertId != null) startScanning() }, 35_000)
                    return
                }
            }
            publish(RadioStatus.Failed("scan", scanFailureText(errorCode)))
        }
    }

    /**
     * Retire notre enregistrement de scan aupres du systeme.
     *
     * Methode et non lambda sur place : ecrite dans l'initialiseur de
     * `scanCallback`, elle s'y serait citee elle-meme et Kotlin ne pouvait plus
     * inferer le type de la propriete.
     */
    private fun dropScanRegistration() {
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
    }

    /** Une seule reprise par demarrage : sinon on boucle sur un defaut reel. */
    private var scanRetried = false

    private fun retryScan(): Boolean {
        if (scanRetried) return false
        scanRetried = true
        main.postDelayed({ if (desiredAdvertId != null) startScanning() }, 400)
        return true
    }

    private fun scanFailureText(code: Int): String = when (code) {
        SCAN_FAILED_ALREADY_STARTED ->
            "Une detection precedente n'a pas pu etre arretee. Coupe puis " +
                "rallume la visibilite."
        SCAN_FAILED_APPLICATION_REGISTRATION_FAILED ->
            "Android a refuse d'enregistrer la detection. Redemarrer le " +
                "Bluetooth regle presque toujours ce cas."
        SCAN_FAILED_INTERNAL_ERROR ->
            "Le Bluetooth de l'appareil a rencontre une erreur interne. " +
                "Coupe puis rallume le Bluetooth."
        SCAN_FAILED_FEATURE_UNSUPPORTED ->
            "Cet appareil ne sait pas faire ce type de detection."
        SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES ->
            "Le Bluetooth de l'appareil est sature par d'autres applications."
        SCAN_FAILED_SCANNING_TOO_FREQUENTLY ->
            "Trop de demarrages de detection en peu de temps. Attends une " +
                "trentaine de secondes."
        else -> "La detection a echoue (code Android $code)."
    }

    private fun startScanning() {
        if (scanning) return
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            publish(RadioStatus.Failed("scan", "Scan indisponible sur cet appareil"))
            return
        }
        // ⚠️ **Un filtre qui accepte TOUT, et le tri se fait en logiciel.**
        //
        // Le filtre precedent portait sur les donnees de fabricant
        // (`setManufacturerData`). C'est la bonne facon de faire *en theorie* :
        // le tri est delegue a la puce, l'application n'est reveillee que pour
        // ce qui l'interesse.
        //
        // En pratique, **ce filtrage materiel est notoirement inegal d'un
        // fabricant a l'autre** : certaines puces ne savent pas appliquer un
        // masque sur les donnees de fabricant et laissent passer tout, d'autres
        // ne laissent rien passer du tout. Le second cas donne exactement ce que
        // Jay a constate le 2026-08-16 : deux appareils qui s'annoncent en
        // parfaite sante, et un seul qui voit l'autre.
        //
        // Le tri logiciel, lui, existait deja dans `onScanResult` et n'a jamais
        // dependu du materiel. Le filtre materiel n'etait donc qu'une
        // optimisation - et une optimisation dont la defaillance est
        // silencieuse et depend de l'appareil est pire que pas d'optimisation.
        //
        // ⚠️ La liste reste NON VIDE : sur plusieurs versions d'Android, un scan
        // sans aucun filtre est refuse ou bride en arriere-plan. Un filtre vide
        // accepte tout tout en gardant le chemin "scan filtre" du systeme.
        //
        // Contrepartie assumee : on est reveille pour chaque annonce BLE des
        // environs, pas seulement les notres. Mesurable via `stats()`.
        val filter = ScanFilter.Builder().build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        scanning = true
    }

    private fun stopScanning() {
        if (!scanning) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
    }

    // ------------------------------------------------------------------
    // ⚠️ **TOUT LE BLOC GATT A ETE SUPPRIME LE 2026-08-27** — serveur, client,
    // file de notifications, connect / disconnect / send / mtuOf. Environ 300
    // lignes, et la moitie des imports Bluetooth de ce fichier.
    //
    // Decision de Jay : *« on n'utilise plus la poignee de main GATT ‹…› le BLE
    // ne sert qu'a valider et authentifier la proximite reelle »*. Ce que le
    // canal transportait — identite d'un inconnu, messagerie, demande d'ami,
    // certificat de croisement — passe par le serveur.
    //
    // ⚠️ **Le cote RECEVEUR part aussi.** Il avait ete garde le temps que le
    // parc se mette a jour ; il n'y a que deux appareils de developpement, tous
    // deux a jour, et aucune production. Un serveur GATT ouvert qui accepte des
    // ecritures que plus rien ne lit n'est pas une compatibilite, c'est une
    // surface d'attaque sans lecteur.
    //
    // ⚠️ **`BleConstants.SERVICE_UUID` partait avec** : verifie a l'inventaire,
    // l'annonce ne porte QUE des `manufacturerData` (voir `advertDataFor`) —
    // aucun UUID de service n'y figure. Le retirer ne change donc rien a ce que
    // les autres appareils entendent.
}
