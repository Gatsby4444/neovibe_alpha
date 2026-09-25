package com.neovibe.neovibe

import com.neovibe.neovibe.ble.ProximityBridge
import com.neovibe.neovibe.events.EventPresenceBridge
import com.neovibe.neovibe.publish.PublishBridge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity (et non FlutterActivity) : CameraX exige un
// LifecycleOwner, que seule la variante Fragment fournit.
class MainActivity : FlutterFragmentActivity() {
    private var nativeCamera: NativeCamera? = null
    /// Pont vers le service de proximité. **Il est jetable** : il naît et meurt
    /// avec l'activité, alors que le service, lui, survit (reconstruction du
    /// 2026-08-16).
    private var proximity: ProximityBridge? = null
    private var nativeMedia: NativeMedia? = null
    private var nativePlayer: NativePlayer? = null
    private var nativeDiagnostics: NativeDiagnostics? = null
    private var deviceIdentity: NativeDeviceIdentity? = null
    private var nativeInstall: NativeInstall? = null
    private var locationGrant: LocationGrant? = null
    private var backgroundGuard: BackgroundGuard? = null
    private var voiceRecorder: NativeVoiceRecorder? = null
    private var nativeGallery: NativeGallery? = null
    /// Pont vers la file de publication — jetable comme celui de la proximité :
    /// le service et ses fichiers survivent à l'activité (2026-09-19).
    private var publish: PublishBridge? = null
    private var eventPresence: EventPresenceBridge? = null
    /// La boussole de la carte (2026-09-25) : n'écoute que si la carte écoute.
    private var heading: com.neovibe.neovibe.location.HeadingSensor? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Journal persistant AVANT tout : il doit capter les crashes de la
        // couche caméra (le processus meurt, le fichier reste).
        CamLog.init(applicationContext)
        nativeCamera = NativeCamera(
            this,
            flutterEngine.renderer,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        proximity = ProximityBridge(
            // `applicationContext` et NON `this` : le pont ne doit pas retenir
            // l'activité, sans quoi on réintroduirait le lien qu'on vient de
            // couper entre la radio et l'interface.
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        nativeMedia = NativeMedia(flutterEngine.dartExecutor.binaryMessenger)
        nativePlayer = NativePlayer(
            applicationContext,
            flutterEngine.renderer,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        nativeDiagnostics = NativeDiagnostics(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // L'identifiant du telephone, pour borner la creation de comptes
        // (2026-09-24). Separe des diagnostics : autre usage, autre regle.
        deviceIdentity = NativeDeviceIdentity(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // `this` et non `applicationContext` : lancer une activite d'installation
        // depuis un contexte d'application exigerait NEW_TASK et perdrait le
        // retour visuel vers l'app.
        nativeInstall = NativeInstall(this, flutterEngine.dartExecutor.binaryMessenger)
        // `applicationContext` : on ne fait que LIRE une permission, il n'y a
        // aucune raison de retenir l'activite pour ca.
        locationGrant = LocationGrant(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // Ce que le telephone accorde a l'app pour vivre en arriere-plan
        // (2026-09-22) : constate et ouvre des pages de reglages, `NEW_TASK`
        // suffit, l'activite n'a rien a y faire.
        backgroundGuard = BackgroundGuard(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // Le micro des messages vocaux (2026-09-13). `applicationContext` :
        // `MediaRecorder` n'a besoin que d'un contexte, pas de l'activite.
        voiceRecorder = NativeVoiceRecorder(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // La galerie du téléphone, lue par nous (2026-09-15) : un
        // `ContentResolver` suffit, l'activite n'a rien a y faire.
        nativeGallery = NativeGallery(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        publish = PublishBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // Ma présence à un événement, app fermée (2026-09-21) : le pont est
        // jetable, le service survit.
        eventPresence = EventPresenceBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        heading = com.neovibe.neovibe.location.HeadingSensor(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onDestroy() {
        // Un ExoPlayer non libéré garde son décodeur matériel : le suivant
        // ouvrirait moins vite, et le service de codecs finirait par refuser.
        nativePlayer?.dispose()
        nativePlayer = null
        nativeDiagnostics?.dispose()
        nativeDiagnostics = null
        deviceIdentity?.dispose()
        deviceIdentity = null
        nativeGallery?.dispose()
        nativeGallery = null
        publish?.dispose()
        publish = null
        eventPresence?.dispose()
        eventPresence = null
        heading?.dispose()
        heading = null
        // Le pont s'en va, le service reste : c'est tout l'intérêt.
        proximity?.dispose()
        proximity = null
        nativeInstall?.dispose()
        nativeInstall = null
        locationGrant?.dispose()
        locationGrant = null
        backgroundGuard?.dispose()
        backgroundGuard = null
        // Un vocal en cours d'enregistrement meurt avec l'ecran : son fichier
        // en clair aussi.
        voiceRecorder?.dispose()
        voiceRecorder = null
        super.onDestroy()
    }
}
