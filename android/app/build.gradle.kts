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
        // ⚠️ **31 (Android 12), décision de Jay du 2026-08-20.**
        //
        // C'était 26 (Android 8). Sur Android 10 et 11, un scan BLE exige
        // `ACCESS_FINE_LOCATION`, et le système ne considère l'app comme « au
        // premier plan » pour la localisation que si son service de premier plan
        // a le type `location` — le nôtre est `connectedDevice`. Interface
        // fermée, `onScanResult` n'aurait donc rien remonté, **sans erreur ni
        // trace**, et tout le travail de reconnaissance native aurait été
        // inutile sur ces versions.
        //
        // Les alternatives revenaient à demander « Autoriser la localisation
        // tout le temps » — l'invite la plus dissuasive d'Android, sur une app
        // dont la thèse est la confiance. On supprime la cause : à partir
        // d'Android 12, `BLUETOOTH_SCAN` + `neverForLocation` dispense de toute
        // permission de localisation.
        //
        // ⚠️ Ne pas redescendre sans relire `RAPPELS.md` #57 : ce nombre porte
        // une décision, pas une contrainte de compilation.
        minSdk = 31
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
