package com.neovibe.neovibe.ble

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
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

    /** Taille attendue d'une trame d'advertising : 2 octets "NV" + 16 d'ID. */
    const val ADVERT_PAYLOAD_SIZE = 18

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

    /**
     * Le service de LOCALISATION du téléphone est éteint — et sur Android ≤ 11,
     * cela suffit à rendre tout scan BLE aveugle.
     *
     * ## Pourquoi ce cas existe, et pourquoi il a coûté une journée
     *
     * Jusqu'à Android 11 inclus, le système considère qu'écouter les
     * identifiants Bluetooth des environs revient à se localiser. Il exige donc
     * **deux choses distinctes**, qu'on confond facilement :
     *
     * 1. la **permission** `ACCESS_FINE_LOCATION` accordée à l'app ;
     * 2. le **service de localisation** allumé sur l'appareil.
     *
     * La première était vérifiée. La seconde, non. Or sans elle `startScan`
     * **réussit** — pas d'exception, pas de code d'erreur, `onScanFailed` n'est
     * jamais appelé — et ne livre **jamais aucun résultat**.
     *
     * C'est le défaut constaté par Jay le 2026-08-16 : sa tablette Android 10
     * affichait diffusion ET détection au vert, et zéro appareil, pendant que
     * son téléphone (Android 12+) voyait la tablette. **L'asymétrie ne venait
     * ni du code ni de la puce : elle venait de la version d'Android.**
     *
     * ⚠️ À partir d'Android 12, `BLUETOOTH_SCAN` avec `neverForLocation` remplace
     * cette exigence — d'où un appareil récent qui marche et un ancien qui ne
     * marche pas, avec exactement le même code.
     */
    object LocationOff : RadioStatus()

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
        is LocationOff -> mapOf("type" to "locationOff")
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
 * Ce que le système exige VRAIMENT, en fonction de la version d'Android.
 *
 * ⚠️ **`ACCESS_FINE_LOCATION` sur Android ≤ 11 n'est pas une formalité** : sans
 * elle, `startScan` réussit et ne renvoie **jamais** le moindre résultat. Aucune
 * exception, aucun code d'erreur — une liste vide, pour toujours. L'ancienne
 * couche Dart demandait cette permission puis **jetait le résultat** (défaut A2
 * du diagnostic). C'est pour ça que ce calcul vit ici, en natif : c'est le seul
 * endroit qui connaît la version réelle du système.
 */
object BlePermissions {

    fun required(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            listOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }

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

    // ⚠️ Sur Android <= 11 SEULEMENT. Au-delà, `BLUETOOTH_SCAN` suffit et
    // exiger la localisation serait une demande abusive.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && !isLocationEnabled(context)) {
        return RadioStatus.LocationOff
    }
    return null
}

/**
 * Le service de localisation est-il allumé ?
 *
 * `isLocationEnabled` existe depuis l'API 28 ; en dessous, on lit le mode dans
 * les réglages. Les deux appareils de test sont au-dessus, mais un `when` qui
 * couvre tout coûte trois lignes et évite un plantage sur un appareil plus
 * ancien.
 */
private fun isLocationEnabled(context: Context): Boolean {
    val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        ?: return false
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        manager.isLocationEnabled
    } else {
        manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }
}
