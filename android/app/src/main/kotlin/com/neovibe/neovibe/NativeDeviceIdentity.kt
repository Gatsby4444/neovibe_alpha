package com.neovibe.neovibe

import android.annotation.SuppressLint
import android.content.Context
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * **L'identifiant de CE telephone, pour borner la creation de comptes**
 * (Jay, 2026-09-24 : *« une securite sur l'appareil lui-meme pour identifier
 * l'appareil et l'empecher de spammer la creation de comptes »*).
 *
 * Rend `Settings.Secure.ANDROID_ID`, tel quel. Depuis Android 8, cette valeur
 * est propre au trio (cle de signature de l'app, utilisateur, appareil) :
 * - elle **survit** a la desinstallation et a la reinstallation de l'app ;
 * - elle ne change qu'a la **remise a zero d'usine** ;
 * - une autre app ne voit pas la meme — ce n'est pas un pisteur partage.
 *
 * ⚠️ **Le natif ne fait que la lire.** L'empreinte (SHA-256 salee, pour que la
 * valeur brute ne quitte jamais le telephone) est calculee en Dart
 * (`device_identity.dart`), et la decision (combien de comptes) est prise par
 * le serveur. Cuisine, serveur et client ne se melangent pas.
 *
 * ⚠️ **Limite assumee** : une app modifiee peut mentir sur cette valeur.
 * « Couteux et visible, pas impossible ».
 */
class NativeDeviceIdentity(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/device")

    init {
        channel.setMethodCallHandler(this)
    }

    // ANDROID_ID est justement ce qu'on veut ici : un identifiant d'appareil
    // propre a l'app, pour une regle anti-abus (usage admis par Google).
    @SuppressLint("HardwareIds")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "androidId") {
            result.notImplemented()
            return
        }
        val id = runCatching {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        }.getOrNull()
        result.success(id)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
