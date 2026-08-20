package com.neovibe.neovibe.ble

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * Constantes du fil BLE NeoVibe.
 *
 * Le format d'advertising est inchangé depuis 2026-07-13 : manufacturerData
 * 0xFFFF, préfixe "NV", puis l'ID ROTATIF de 16 octets (HMAC du créneau de
 * 15 min — voir `ProximityIdentity` côté Dart). Le natif ne sait pas ce que
 * cet ID veut dire ; il le diffuse et le rapporte, rien de plus.
 */
object BleConstants {
    const val MANUFACTURER_ID = 0xFFFF
    val MAGIC = byteArrayOf(0x4E, 0x56) // "NV"

    /**
     * Version du protocole d'annonce, portee dans chaque annonce.
     *
     * ⚠️ **Un octet aujourd'hui, une migration entiere si on l'oublie.** Sans
     * lui, deux versions qui ne se comprennent pas ne se voient simplement pas,
     * sans erreur ni trace. Doit rester egal a
     * `ProximityIdentity.protocolVersion` cote Dart.
     *
     * 3 = un jeton par PAIRE (2026-08-20). 2 = cle de diffusion partagee.
     */
    const val PROTOCOL_VERSION: Byte = 3

    /** 2 octets "NV" + 1 de version + 16 d'identifiant. */
    const val ADVERT_PAYLOAD_SIZE = 19

    val SERVICE_UUID: UUID = UUID.fromString("53d70001-8a3f-4f95-9b6c-4e656f566962")
    val RX_UUID: UUID = UUID.fromString("53d70002-8a3f-4f95-9b6c-4e656f566962")
    val TX_UUID: UUID = UUID.fromString("53d70003-8a3f-4f95-9b6c-4e656f566962")
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /** MTU par défaut du BLE tant que la négociation n'a pas abouti. */
    const val DEFAULT_MTU = 23
}

/**
 * L'état RÉEL de la radio — le cœur de la reconstruction du 2026-08-16.
 *
 * ## Pourquoi ce type existe
 *
 * L'ancienne couche native répondait `success` à `start()` **sans condition**,
 * alors que trois de ses chemins se terminaient par un `?: return` silencieux
 * (advertiser, scanner et serveur GATT sont **null** quand le Bluetooth est
 * éteint). L'interface annonçait donc « les autres peuvent te voir » avec zéro
 * radio active, et rallumer le Bluetooth ne relançait rien.
 *
 * Le diagnostic du 2026-08-16 (§A1, §A2) a montré que **trois causes sans
 * rapport produisaient le même écran vide** : Bluetooth éteint, permission
 * manquante, et poignée de main en cours. Tant qu'elles ne sont pas
 * distinguables, aucun test de proximité n'est interprétable.
 *
 * ⚠️ **Règle à tenir** : ce type n'a **aucune** valeur signifiant « peut-être ».
 * Chaque cas nomme une cause précise et actionnable. Un état qu'on ne sait pas
 * nommer est un état qu'on ne saura pas corriger.
 */
sealed class RadioStatus {

    /** L'appareil n'a pas le Bluetooth LE. Rien ne sera jamais possible ici. */
    object Unsupported : RadioStatus()

    /**
     * Il manque des permissions, et on dit **lesquelles** — l'interface peut
     * ainsi proposer exactement la bonne action.
     */
    data class PermissionsMissing(val missing: List<String>) : RadioStatus()

    /** Le Bluetooth est éteint. L'utilisateur doit l'allumer. */
    object AdapterOff : RadioStatus()

    // ⚠️ **`LocationOff` a été SUPPRIMÉ le 2026-08-20, avec `minSdk = 31`.**
    //
    // Il disait « la localisation du téléphone est éteinte, donc le scan BLE ne
    // rend rien » — le défaut constaté par Jay le 2026-08-16 sur sa tablette
    // Android 10 : diffusion et détection au vert, zéro appareil, pendant que
    // son téléphone Android 12 voyait la tablette.
    //
    // À partir d'Android 12, `BLUETOOTH_SCAN` avec `neverForLocation` remplace
    // cette exigence : l'état ne peut plus se produire, et le garder ferait
    // croire qu'il le peut.
    //
    // ⚠️ S'il fallait un jour redescendre sous Android 12, ce n'est pas ce seul
    // état qu'il faudrait rétablir : voir `RAPPELS.md` #57 pour la chaîne
    // entière (permission de fond, type du service de premier plan, invite).

    /** Tout est possible, mais personne n'a demandé à être visible. */
    object Idle : RadioStatus()

    /** Démarrage en cours (l'advertising met quelques centaines de ms). */
    object Starting : RadioStatus()

    /**
     * En marche. [advertising] et [scanning] sont **mesurés**, pas supposés :
     * l'advertising peut échouer seul (`onStartFailure`) sans emporter le scan.
     */
    data class Running(val advertising: Boolean, val scanning: Boolean) : RadioStatus()

    /** Échec nommé, remonté tel quel à l'interface. */
    data class Failed(val code: String, val message: String) : RadioStatus()

    /** Sérialisation vers le Dart. La clé `type` est le discriminant. */
    fun toMap(): Map<String, Any?> = when (this) {
        is Unsupported -> mapOf("type" to "unsupported")
        is PermissionsMissing -> mapOf("type" to "permissionsMissing", "missing" to missing)
        is AdapterOff -> mapOf("type" to "adapterOff")
        is Idle -> mapOf("type" to "idle")
        is Starting -> mapOf("type" to "starting")
        is Running -> mapOf(
            "type" to "running",
            "advertising" to advertising,
            "scanning" to scanning,
        )
        is Failed -> mapOf("type" to "failed", "code" to code, "message" to message)
    }
}

/**
 * Ce que le système exige VRAIMENT pour la radio.
 *
 * ⚠️ **Ce calcul vit en natif, et il doit y rester.** L'ancienne couche Dart
 * demandait les permissions puis **jetait le résultat** (défaut A2 du
 * diagnostic) : elle décidait de ce qu'Android exige sans le lui demander. Ici,
 * c'est le système qui répond.
 *
 * ⚠️ **Une permission refusée ne se voit pas.** `startScan` réussit sans elle —
 * aucune exception, aucun code d'erreur — et ne renvoie jamais le moindre
 * résultat. Une liste vide, pour toujours. D'où le contrôle explicite avant de
 * démarrer, plutôt qu'un échec qu'on attendrait en vain.
 */
object BlePermissions {

    // ⚠️ **Une seule liste depuis `minSdk = 31`** (2026-08-20). Il y avait une
    // branche pour Android <= 11 qui exigeait `ACCESS_FINE_LOCATION` : elle est
    // devenue inatteignable, et une branche morte finit toujours par être lue
    // comme une branche vivante.
    //
    // ⚠️ Aucune permission de localisation, et c'est délibéré : `BLUETOOTH_SCAN`
    // est déclarée avec `neverForLocation`, donc nous affirmons ne dériver
    // aucune position des annonces captées. En demander une contredirait cette
    // déclaration.
    fun required(): List<String> = listOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_ADVERTISE,
        Manifest.permission.BLUETOOTH_CONNECT,
    )

    fun missing(context: Context): List<String> = required().filter {
        ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }
}

/**
 * Diagnostic matériel : ce que la radio peut faire, ici et maintenant.
 *
 * Rendu comme un [RadioStatus] d'échec, ou `null` si rien ne s'oppose au
 * démarrage. Un seul endroit décide — le moteur n'a plus qu'à obéir.
 */
fun evaluateRadio(context: Context): RadioStatus? {
    if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
        return RadioStatus.Unsupported
    }
    val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    val adapter: BluetoothAdapter? = manager?.adapter
    if (adapter == null) return RadioStatus.Unsupported

    val missing = BlePermissions.missing(context)
    if (missing.isNotEmpty()) return RadioStatus.PermissionsMissing(missing)

    if (!adapter.isEnabled) return RadioStatus.AdapterOff

    // ⚠️ **Plus aucun contrôle de localisation ici.** Il n'avait de sens que sous
    // Android 12, et `minSdk = 31` rend ce cas inatteignable (2026-08-20).
    return null
}

