import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ⚠️ **LA CLÉ DE SIGNATURE — irremplaçable, et hors du dépôt.**
//
// Créée le 2026-08-25 après la panne « Signatures d'application en conflit
// (-7) » chez Jay. Jusque-là, les APK de release étaient signés avec la clé de
// **debug**, qui est générée **par machine** : le changement de PC du même jour
// a suffi à rendre toute mise à jour impossible sur les appareils de test.
// C'était la dette `RAPPELS.md` #13, ouverte depuis le 2026-07-26.
//
// `key.properties` et le `.jks` sont gitignorés. **Les sauvegarder hors de
// cette machine et les joindre au paquet de transfert** — leur absence est
// exactement ce qui a cassé la bascule du 2026-08-25.
//
// Repli sur la clé de debug si le fichier manque : un clone frais doit pouvoir
// compiler. L'APK produit ne s'installera simplement pas par-dessus un APK
// officiel, et c'est le comportement voulu — mieux vaut un échec d'installation
// qu'un APK signé par une clé inconnue qui prendrait sa place.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.neovibe.neovibe"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Requis par flutter_local_notifications (API java.time sur minSdk 26)
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.neovibe.neovibe"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ⚠️ **29 (Android 10), décision de Jay du 2026-08-25.**
        //
        // Historique de ce nombre, parce qu'il a bougé deux fois et que chaque
        // valeur portait une décision :
        //
        // - **26** jusqu'au 2026-08-20 (BLE stable + canaux de notification).
        // - **31** le 2026-08-20 : sur Android 10 et 11, un scan BLE exige
        //   `ACCESS_FINE_LOCATION`, et le système ne considère l'app comme « au
        //   premier plan » pour la localisation que si son service de premier
        //   plan a le type `location` — le nôtre était `connectedDevice`.
        //   Interface fermée, `onScanResult` ne remontait rien, **sans erreur ni
        //   trace**. On avait supposé que la seule sortie était de demander
        //   « Autoriser la localisation tout le temps ».
        // - **29** le 2026-08-25 : **cette supposition était fausse.** Un service
        //   de premier plan de type `location` fait compter l'app comme « au
        //   premier plan » pour la localisation ; `ACCESS_FINE_LOCATION` en
        //   « pendant l'utilisation » suffit alors, même interface fermée.
        //   `ACCESS_BACKGROUND_LOCATION` ne servirait qu'à **démarrer** un scan
        //   sans interface, ce que nous ne faisons jamais. **Constaté sur le
        //   manifeste FUSIONNÉ le 2026-08-25**, et non sur le nôtre : le seul
        //   receveur `BOOT_COMPLETED` est celui du plugin
        //   `flutter_foreground_task`, désarmé par `autoRunOnBoot: false`
        //   (`lib/main.dart:120`) ; `ProximityService` ne part que de l'écran
        //   Ping. L'invite dissuasive n'est donc jamais requise.
        //
        // ⚠️ **Pourquoi 29 et pas 26** : Android 8/9 ont un troisième modèle de
        // permission (COARSE suffit, et les types de service de premier plan
        // n'existent pas avant l'API 29). Ce serait une branche de plus, que le
        // seul appareil de test pré-12 disponible — la tablette d'Android 10 —
        // ne pourrait pas exercer. On ne code pas un chemin qu'on ne peut pas
        // éprouver : c'est exactement ce qui a produit le défaut du 2026-08-20.
        //
        // ⚠️ Ne pas bouger ce nombre sans relire `RAPPELS.md` #57.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // ⚠️ **LE `versionCode` A FAIT UN SAUT À 3000 LE 2026-08-25, ET IL NE
        // FAUT JAMAIS LE REDESCENDRE.**
        //
        // Les releases v0.9.114 à v0.9.121 ont été publiées en APK **découpés
        // par architecture** (`--split-per-abi`). Flutter y ajoute alors un
        // décalage au `versionCode` : 1000 pour armeabi-v7a, **2000 pour
        // arm64-v8a**, 4000 pour x86_64. Le `0.9.119+209` livré à Jay portait
        // donc `versionCode = 2209`, et non 209.
        //
        // À partir de la v0.9.122 les APK sont redevenus **complets**, donc sans
        // décalage : 212, 213, 214, 215 — tous **inférieurs à 2209**. Android a
        // refusé les quatre avec `INSTALL_FAILED_VERSION_DOWNGRADE (-25)`, et
        // rien ne l'avait signalé côté build : l'APK se construit parfaitement,
        // c'est l'INSTALLATION qui échoue, chez Jay.
        //
        // ⚠️ **La leçon, plus large que le nombre** : `versionName` et
        // `versionCode` sont deux choses distinctes. Android ne lit QUE le
        // second, et **changer le format de livraison change le second sans
        // qu'on le demande**. Ne jamais mélanger APK complet et APK découpé sur
        // un même canal de distribution.
        //
        // 3000 laisse la place à un éventuel retour au découpage (arm64 vaudrait
        // alors 2000 + 3000 = 5000, toujours croissant).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val store = keyProperties.getProperty("storeFile")
            if (store != null) {
                storeFile = rootProject.file(store)
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // ⚠️ **Le repli sur la clé de debug DOIT rester bruyant.** Un APK
            // signé par une clé de debug ressemble en tout point à un APK
            // officiel : même nom, même icône, même numéro de version. Seule
            // l'empreinte du certificat les distingue, et personne ne la lit.
            signingConfig = if (keyProperties.getProperty("storeFile") != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "NEOVIBE : android/key.properties introuvable — APK signé " +
                        "avec la clé de DEBUG. Il ne s'installera PAS par-dessus " +
                        "une version officielle. Voir RAPPELS.md #13 et #61.",
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

// ============================================================================
// LA PREUVE DE ROTATION, IMPOSÉE PAR LA CONSTRUCTION
// ============================================================================
//
// ## 🔴 Pourquoi ceci vit ICI et plus dans un script
//
// `RAPPELS.md` #61 disait, noir sur blanc, depuis le 2026-08-25 : *« ne plus
// jamais publier un APK produit par `flutter build apk --release` seul »*. La
// panne est quand même arrivée **trois fois** — dont deux releases publiées
// exactement comme ça le 2026-08-27.
//
// ⚠️ **Une consigne écrite est un garde-fou, et `CLAUDE.md` dit qu'un garde-fou
// est un aveu** : il faut le maintenir, le comprendre, et ne jamais le
// contourner par mégarde. Un script aussi se contourne — il suffit de ne pas
// l'appeler. Ici il n'y a plus de chemin : **toute** construction de release
// passe par la tâche d'empaquetage, donc par cette signature.
//
// ## Ce que la signature d'AGP ne sait pas faire
//
// Le bloc `signingConfigs` ci-dessus signe avec la nouvelle clé, en v3. Il ne
// sait **pas** joindre la preuve de rotation (`--lineage`) : le plugin Android
// n'expose aucune propriété pour ça. Un APK ainsi signé s'installe sur un
// appareil neuf et **refuse de s'installer par-dessus une version signée par
// l'ancienne clé** — c'est-à-dire sur les appareils de test de Jay, et
// uniquement là. Rien ne le signale à la construction.
//
// ## ⚠️ Trois portes, trois comportements — et aucune n'est silencieuse
//
// | Situation | Ce qui se passe |
// |---|---|
// | pas de `key.properties` | clé de debug, aucune rotation à prouver — un clone frais compile |
// | `key.properties` **et** les fichiers de rotation | resignature avec la preuve, puis **vérification sur l'artefact** |
// | `key.properties` **sans** les fichiers de rotation | 🔴 **la construction ÉCHOUE** |
//
// La troisième ligne est celle qui compte. Produire un APK signé par la vraie
// clé **sans** la preuve, c'est fabriquer un artefact qui ressemble en tout
// point à un APK officiel et ne s'installe nulle part. Mieux vaut ne pas le
// produire du tout : une règle de sécurité s'énonce positivement (`CLAUDE.md`,
// règle 4) — « cet APK n'existe pas » vaut mieux que « cet APK existe mais ne
// s'installe pas ».
val dossierDocdev = rootProject.file("../docdev")
val fichiersRotation = mapOf(
    "lignage" to File(dossierDocdev, "lineage-neovibe.bin"),
    "ancienne cle" to File(dossierDocdev, "ancienne-cle-debug.keystore"),
    "mot de passe" to File(dossierDocdev, "keystore-password.txt"),
    "nouvelle cle" to File(dossierDocdev, "neovibe-release.jks"),
)

/** L'`apksigner` du build-tools le plus recent du SDK. */
fun apksignerBinaire(sdk: File): File {
    val dossiers = File(sdk, "build-tools").listFiles()?.sortedBy { it.name }
        ?: error("NEOVIBE : aucun build-tools dans " + sdk)
    val nom = if (System.getProperty("os.name").startsWith("Windows", true)) {
        "apksigner.bat"
    } else {
        "apksigner"
    }
    return File(dossiers.last(), nom)
}

/**
 * Lance une commande et rend sa sortie. Echoue bruyamment.
 *
 * ⚠️ `ProcessBuilder` plutot que `project.exec` : ce bloc tourne dans un
 * `doLast`, et y toucher au `project` casse le cache de configuration de
 * Gradle — une panne lointaine et incomprehensible.
 */
fun lanceEtRend(commande: List<String>, quoi: String): String {
    val processus = ProcessBuilder(commande).redirectErrorStream(true).start()
    val sortie = processus.inputStream.bufferedReader().readText()
    if (processus.waitFor() != 0) {
        error("NEOVIBE : " + quoi + " a echoue.\n" + sortie)
    }
    return sortie
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        val suffixe = variant.name.replaceFirstChar { it.uppercase() }
        val sdk = android.sdkDirectory
        val signeAvecLaVraieCle = keyProperties.getProperty("storeFile") != null
        val dossierApk = layout.buildDirectory.dir("outputs/apk/" + variant.name)

        tasks.matching { it.name == "package" + suffixe }.configureEach {
            doLast {
                if (!signeAvecLaVraieCle) {
                    logger.lifecycle(
                        "NEOVIBE : cle de debug — pas de preuve de rotation a joindre.",
                    )
                    return@doLast
                }

                val manquants = fichiersRotation.filterValues { !it.exists() }
                if (manquants.isNotEmpty()) {
                    error(
                        "NEOVIBE : signature de release IMPOSSIBLE — " +
                            manquants.keys.joinToString(", ") +
                            " introuvable(s) dans docdev/.\n" +
                            "Ces fichiers sont hors depot et DOIVENT suivre le projet " +
                            "d'une machine a l'autre (RAPPELS.md #13 et #61).\n" +
                            "Sans eux, l'APK serait signe par la vraie cle SANS la " +
                            "preuve de rotation : il ne s'installerait sur aucun " +
                            "appareil de test, et rien ne le signalerait.",
                    )
                }

                val apksigner = apksignerBinaire(sdk)
                val motDePasse = fichiersRotation.getValue("mot de passe").readText().trim()
                val apks = dossierApk.get().asFile
                    .listFiles { f: File -> f.name.endsWith(".apk") }
                    ?.toList()
                    .orEmpty()
                if (apks.isEmpty()) {
                    error("NEOVIBE : aucun APK dans " + dossierApk.get())
                }

                apks.forEach { apk ->
                    // ⚠️ **L'ordre compte : le signataire le PLUS ANCIEN d'abord.**
                    // ⚠️ v1 et v2 ne portent pas deux signataires ; `minSdk` vaut 29
                    //    et le schema v3 existe depuis l'API 28.
                    lanceEtRend(
                        listOf(
                            apksigner.absolutePath, "sign",
                            "--lineage", fichiersRotation.getValue("lignage").absolutePath,
                            "--min-sdk-version", "29",
                            "--v1-signing-enabled", "false",
                            "--v2-signing-enabled", "false",
                            "--v3-signing-enabled", "true",
                            "--ks", fichiersRotation.getValue("ancienne cle").absolutePath,
                            "--ks-pass", "pass:android",
                            "--ks-key-alias", "androiddebugkey",
                            "--key-pass", "pass:android",
                            "--next-signer",
                            "--ks", fichiersRotation.getValue("nouvelle cle").absolutePath,
                            "--ks-pass", "pass:" + motDePasse,
                            "--ks-key-alias", "neovibe",
                            "--key-pass", "pass:" + motDePasse,
                            apk.absolutePath,
                        ),
                        "la signature de " + apk.name,
                    )

                    // ⚠️ **On VERIFIE l'artefact, on ne croit pas la commande.**
                    // « la signature a reussi » et « l'APK porte les deux
                    // signataires » ne sont pas la meme chose — et c'est la
                    // seconde qui decide chez Jay.
                    val preuve = lanceEtRend(
                        listOf(
                            apksigner.absolutePath, "verify", "--print-certs",
                            apk.absolutePath,
                        ),
                        "la verification de " + apk.name,
                    )
                    val porteNeoVibe = preuve.contains("CN=NeoVibe")
                    val porteAncienne = preuve.contains("CN=Android Debug")
                    if (!porteNeoVibe || !porteAncienne) {
                        error(
                            "NEOVIBE : " + apk.name + " ne porte pas les DEUX " +
                                "signataires attendus (NeoVibe : " + porteNeoVibe +
                                ", ancienne : " + porteAncienne + ").\n" +
                                "Il ne s'installerait pas par-dessus une version " +
                                "anterieure. Construction interrompue.\n" + preuve,
                        )
                    }
                    logger.lifecycle(
                        "NEOVIBE : " + apk.name + " signe avec la preuve de rotation " +
                            "(NeoVibe + ancienne cle), verifie sur l'artefact.",
                    )
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Couche caméra native NeoVibe (CameraX) — double flux Oneshot, bascule
    // en cours de vidéo (enregistrement persistant), FLAG_SECURE.
    val cameraxVersion = "1.4.2"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-video:$cameraxVersion")
    implementation("androidx.exifinterface:exifinterface:1.3.7")

    // Lecteur vidéo NATIF des médias scellés (NativePlayer.kt) — décision de
    // Jay 2026-08-12 : le lecteur lit notre format par blocs directement, sans
    // serveur HTTP local. Version alignée sur celle que `video_player_android`
    // apporte déjà : deux versions de media3 dans un même APK ne se concilient
    // pas, et la plus haute gagnerait en silence.
    val media3Version = "1.9.2"
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-datasource:$media3Version")
    implementation("androidx.media3:media3-common:$media3Version")

    // Vecteurs de test croisés du format scellé (voir docs/format-media-scelle.md)
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.google.code.gson:gson:2.11.0")
}

flutter {
    source = "../.."
}
