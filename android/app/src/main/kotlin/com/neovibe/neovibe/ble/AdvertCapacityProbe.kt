package com.neovibe.neovibe.ble

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.content.Context
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * **Combien de jeux d'annonces cette PUCE accepte-t-elle vraiment ?**
 *
 * ## Pourquoi cette sonde existe — 2026-09-01
 *
 * [BleEngine.advertMaxSets] vaut 6, et son propre commentaire dit ce qu'il faut
 * en penser : *« une borne RAISONNEE, pas mesuree […] les controleurs BLE
 * courants tiennent 4 a 8 jeux ; aucune API ne le dit »*. Au-dela on retombe en
 * mode cycle, ou le jeton d'un ami n'est en l'air que 1/N du temps — le defaut
 * d'echelle que le mode parallele existe pour supprimer, reintroduit des six
 * jetons, c'est-a-dire des cinq amis.
 *
 * La monter au jugé ne ferait que **deplacer la supposition** (`RAPPELS.md`
 * #113). Cette sonde la remplace par un fait : on demande des jeux a la pile, un
 * par un, et on compte ceux qu'elle **accepte**.
 *
 * ## ⚠️ Elle n'est PAS le systeme automatique — elle le raccourcit
 *
 * Depuis le 2026-09-01, l'appareil apprend son plafond **tout seul** : il part
 * de `BleEngine.PLAFOND_DE_DEPART`, la pile refuse un jour, et le moteur retient
 * ce qu'elle avait accorde ([AdvertCapacityStore]). Aucune intervention, sur
 * n'importe quel telephone.
 *
 * Cette sonde sert a **ne pas attendre ce jour-la** : elle provoque l'essai tout
 * de suite, au lieu de le laisser arriver la premiere fois que l'utilisateur
 * aura assez d'amis — moment ou il paierait un repli en mode cycle. Son
 * resultat va dans le meme magasin : **une seule memoire, deux facons de la
 * remplir**, jamais deux chiffres a tenir d'accord.
 *
 * ## Ce qu'elle mesure, et ce qu'elle ne mesure pas
 *
 * | Question | Reponse |
 * |---|---|
 * | Combien de jeux le controleur accepte de demarrer | **oui** — c'est tout l'objet |
 * | Est-ce que le voisin les recoit tous | **non** — il faut un second appareil |
 * | Est-ce que ca tient dans la duree | **non** — la sonde raccroche aussitot |
 *
 * ⚠️ **Elle refuse de tourner pendant que le service emet.** Les jeux d'annonces
 * se partagent le meme budget de controleur : mesurer par-dessus une emission en
 * cours donnerait la capacite RESTANTE, pas le plafond — un chiffre plus petit,
 * indiscernable du vrai, et qui ferait conclure a l'envers.
 *
 * ⚠️ **La sonde n'emet aucun jeton NeoVibe.** Sa charge utile a la meme taille
 * qu'une annonce reelle (les parametres pesent sur le plafond, donc ils sont ceux
 * de la production), mais son entete n'est pas `NV` : aucun NeoVibe en face ne
 * peut la prendre pour un jeton, ni la compter comme un croisement.
 */
object AdvertCapacityProbe {

    /** Jusqu'ou on demande. Au-dela, le chiffre n'interesse plus personne. */
    private const val PLAFOND = 12

    /** Ce qu'on accorde a la pile pour repondre d'un jeu. */
    private const val DELAI_PAR_JEU_MS = 2500L

    /**
     * L'entete de la sonde. **Deliberement differente de [BleConstants.MAGIC].**
     *
     * `SO` comme sonde : un scanner NeoVibe jette la trame avant meme de lire la
     * version, exactement comme il jette n'importe quel autre annonceur.
     */
    private val ENTETE_SONDE = byteArrayOf(0x53, 0x4F)

    /** Un refus leve par la pile avant meme d'atteindre le rappel. */
    private const val CODE_EXCEPTION = -1

    private val enCours = AtomicBoolean(false)

    /**
     * Mesure, puis rend des FAITS.
     *
     * ⚠️ **Bloquante** : les rappels d'annonce arrivent sur le fil principal, donc
     * l'attente doit se faire ailleurs. C'est a l'appelant de la lancer sur un fil
     * de fond — [ProximityBridge] s'en charge.
     */
    fun mesure(context: Context): Map<String, Any?> {
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
            ?.adapter
            ?: return refus("pas d'adaptateur Bluetooth")

        // ⚠️ **Un seul endroit dit ce que le systeme exige** — `evaluateRadio`,
        // deja utilise par `probe` et par l'interface. En reecrire une variante
        // ici, c'est se garantir qu'un jour les deux ne diront plus la meme
        // chose : la sonde repondrait « Bluetooth eteint » quand l'app repond
        // « permission manquante ».
        val blocage = evaluateRadio(context)
        if (blocage != null) return refus("radio indisponible", blocage.toMap())

        if (ProximityService.instance != null) {
            return refus("la radio de proximite tourne — arrete-la pour mesurer le plafond")
        }
        if (!adapter.isMultipleAdvertisementSupported) {
            return refus("cette puce ne fait pas d'annonces multiples")
        }
        if (!enCours.compareAndSet(false, true)) return refus("une mesure est deja en cours")

        val advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            enCours.set(false)
            return refus("aucun annonceur disponible")
        }

        // ⚠️ **Les parametres de la production, lus au meme endroit qu'elle.**
        // Le plafond peut dependre du mode : mesurer une autre emission rendrait
        // un chiffre exact pour une emission qu'on ne fait pas.
        val params = neoAdvertParams()

        val rappels = ArrayList<SondeCallback>()
        var acceptes = 0
        var codeRefus: Int? = null
        var expire = false

        try {
            for (rang in 0 until PLAFOND) {
                val callback = SondeCallback()
                rappels.add(callback)
                try {
                    advertiser.startAdvertisingSet(
                        params,
                        donneesSonde(rang),
                        null,
                        null,
                        null,
                        callback,
                    )
                } catch (e: Exception) {
                    // Un refus immediat : argument invalide, permission absente,
                    // pile saturee. Il compte comme la reponse du rang courant.
                    codeRefus = CODE_EXCEPTION
                    callback.abandonne()
                    break
                }
                if (!callback.attend()) {
                    expire = true
                    break
                }
                if (callback.statut != AdvertisingSetCallback.ADVERTISE_SUCCESS) {
                    codeRefus = callback.statut
                    break
                }
                acceptes++
            }
        } finally {
            // ⚠️ **Tout raccrocher, meme le rang qui a echoue.** Un jeu laisse en
            // l'air continuerait de crier une charge de sonde apres la mesure.
            rappels.forEach { runCatching { advertiser.stopAdvertisingSet(it) } }
            enCours.set(false)
        }

        // ⚠️ **Le constat va dans la memoire de l'appareil, pas seulement a
        // l'ecran.** Une mesure qu'on affiche sans la retenir demande a
        // l'utilisateur d'etre l'endroit ou vit le resultat — exactement ce que
        // Jay a refuse : *« il faut que cela soit autonome sur n'importe quel
        // appareil ».*
        //
        // ⚠️ **Sauf si la sonde s'est arretee d'elle-meme** : elle a alors
        // touche SA borne, pas celle de la puce. Ecrire ce chiffre ferait passer
        // « je n'ai pas cherche plus loin » pour « la puce s'arrete la ».
        if (acceptes >= 1 && acceptes < PLAFOND) {
            AdvertCapacityStore.ecrire(context, acceptes)
        }

        return mapOf(
            "ok" to true,
            "acceptes" to acceptes,
            "demandes" to PLAFOND,
            "plafondCourant" to BleEngine.PLAFOND_DE_DEPART,
            "plafondRetenu" to AdvertCapacityStore.lire(context),
            "codeRefus" to codeRefus,
            "expire" to expire,
            "extendedSupporte" to adapter.isLeExtendedAdvertisingSupported,
            "tailleMaxAnnonce" to adapter.leMaximumAdvertisingDataLength,
            "appareil" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
            "sdk" to android.os.Build.VERSION.SDK_INT,
        )
    }

    /** 20 octets, comme une annonce reelle — mais avec l'entete de la sonde. */
    private fun donneesSonde(rang: Int): AdvertiseData {
        val charge = ByteArray(BleConstants.ADVERT_PAYLOAD_SIZE)
        ENTETE_SONDE.copyInto(charge)
        charge[3] = rang.toByte()
        return AdvertiseData.Builder()
            .addManufacturerData(BleConstants.MANUFACTURER_ID, charge)
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(true)
            .build()
    }

    private fun refus(raison: String, blocage: Map<String, Any?>? = null): Map<String, Any?> =
        mapOf("ok" to false, "raison" to raison, "blocage" to blocage)

    /**
     * Un jeu de sonde, et l'attente de la reponse de la pile.
     *
     * ⚠️ **`startAdvertisingSet` ne rend rien** : elle ne dit ni oui ni non. Sans
     * ce rappel, la sonde compterait ses propres DEMANDES et rendrait toujours
     * [PLAFOND] — un instrument dont le resultat serait impose par sa forme
     * plutot que mesure.
     */
    private class SondeCallback : AdvertisingSetCallback() {
        private val porte = CountDownLatch(1)

        @Volatile
        var statut: Int = ADVERTISE_FAILED_INTERNAL_ERROR
            private set

        override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
            statut = status
            porte.countDown()
        }

        /** Vrai si la pile a repondu dans le temps imparti. */
        fun attend(): Boolean = porte.await(DELAI_PAR_JEU_MS, TimeUnit.MILLISECONDS)

        /** La demande n'a jamais atteint la pile : personne ne repondra. */
        fun abandonne() = porte.countDown()
    }
}
