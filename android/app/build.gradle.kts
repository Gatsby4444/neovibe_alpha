plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
