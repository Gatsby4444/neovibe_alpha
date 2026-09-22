package com.neovibe.neovibe

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * **Ce que le telephone accorde a l'app pour vivre en arriere-plan.**
 *
 * ## Pourquoi ce fichier existe : l'apres-midi du 2026-09-21
 *
 * Le carnet du service radio (`dev_reports` `a2c09b93…`) montre le service
 * mort a ~13:45, sur batterie, apres quatre « memoire basse » — et **rien
 * jusqu'a 21:41** : ni relance par Android (`START_STICKY`), ni sonnerie de
 * l'alarme posee pour 13:45. Une mort propre d'Android relance le service et
 * livre l'alarme ; ici ni l'un ni l'autre. C'est un arret facon « forcer
 * l'arret », celui que MIUI applique a une app hors de sa liste blanche.
 *
 * Les captures de Jay du 2026-09-22 le confirment : *Economiseur de batterie
 * (recommande)* au lieu de *Pas de restriction*, et *Demarrage automatique en
 * arriere-plan* desactive. Aucune ligne de code ne peut changer ces reglages a
 * la place de l'utilisateur ; ce pont sert a **constater** ce qui est lisible
 * et a **emmener** l'utilisateur au bon endroit.
 *
 * ## Ce qui est lisible, et ce qui ne l'est pas
 *
 * | reglage | lisible ? | comment |
 * |---|---|---|
 * | exemption de l'optimisation batterie (Android) | **oui** | `PowerManager.isIgnoringBatteryOptimizations` |
 * | economiseur MIUI « Pas de restriction » | non | c'est le meme interrupteur que l'exemption Android sur MIUI recent ; on lit celle-ci |
 * | demarrage automatique MIUI | **non** | aucune API publique ; on ouvre la page et on le dit |
 *
 * ## Ce que ce pont ne fait pas
 *
 * Il ne decide pas quand deranger l'utilisateur : c'est la vue
 * (`background_guard_screen.dart`) qui le sait. Il ne demande rien de
 * lui-meme. Et il ne devine pas MIUI a la marque : il regarde si la page MIUI
 * **existe** (`resolveActivity`), ce qui est un fait — d'ou les `<queries>`
 * du manifeste, sans lesquelles Android 11+ repond « n'existe pas » a tout.
 */
class BackgroundGuard(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "neovibe/background_guard")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> result.success(state())
            "requestBatteryExemption" -> result.success(requestBatteryExemption())
            "openAutostart" -> result.success(ouvre(autostartIntent()))
            "openBatterySaver" -> result.success(ouvre(batterySaverIntent()))
            "openAppDetails" -> result.success(ouvre(appDetailsIntent()))
            else -> result.notImplemented()
        }
    }

    /** Les faits, tels qu'Android les donne. Aussi relus par le diagnostic. */
    fun state(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "brand" to Build.BRAND,
        "model" to Build.MODEL,
        "batteryExempt" to exempt(),
        "autostartPage" to (resolvable(autostartIntent())),
        "batterySaverPage" to (resolvable(batterySaverIntent())),
    )

    private fun exempt(): Boolean =
        context.getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(context.packageName) == true

    /**
     * La boite de dialogue standard d'Android « Autoriser NeoVibe a ignorer
     * l'optimisation de la batterie ? ». Exige
     * `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` au manifeste.
     *
     * ⚠️ Google Play n'accepte cette permission que si la fonction principale
     * de l'app en depend. La notre — reconnaitre ses amis a cote de soi, ecran
     * eteint — en depend entierement ; c'est la justification a donner.
     */
    private fun requestBatteryExemption(): Boolean {
        if (exempt()) return true
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:" + context.packageName))
        if (ouvre(intent)) return true
        // Certains constructeurs retirent la boite de dialogue : la liste
        // generale des exemptions reste, et l'utilisateur y trouve l'app.
        return ouvre(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    /** La page « Demarrage automatique » du Centre de securite MIUI. */
    private fun autostartIntent(): Intent = Intent()
        .setClassName(
            "com.miui.securitycenter",
            "com.miui.permcenter.autostart.AutoStartManagementActivity",
        )

    /**
     * La page « Economiseur de batterie » de MIUI **pour cette app**
     * (celle de la premiere capture de Jay : Pas de restriction / recommande /
     * restreindre). Les deux extras sont ceux que MIUI lit.
     */
    private fun batterySaverIntent(): Intent = Intent()
        .setClassName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
        .putExtra("package_name", context.packageName)
        .putExtra("package_label", label())

    private fun appDetailsIntent(): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:" + context.packageName))

    private fun label(): String = runCatching {
        context.packageManager.getApplicationLabel(context.applicationInfo).toString()
    }.getOrDefault("NeoVibe")

    private fun resolvable(intent: Intent): Boolean =
        runCatching { intent.resolveActivity(context.packageManager) != null }
            .getOrDefault(false)

    /**
     * Lance une page de reglages depuis le contexte d'application : d'ou
     * `NEW_TASK`. Rend `false` si la page n'existe pas ou refuse de s'ouvrir
     * — la vue affiche alors le chemin a la main, au lieu d'un bouton mort.
     */
    private fun ouvre(intent: Intent): Boolean {
        if (!resolvable(intent)) return false
        return runCatching {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        }.getOrDefault(false)
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
