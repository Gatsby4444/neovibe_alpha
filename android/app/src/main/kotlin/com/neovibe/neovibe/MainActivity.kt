package com.neovibe.neovibe

import com.neovibe.neovibe.ble.ProximityBridge
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
    }

    override fun onDestroy() {
        // Un ExoPlayer non libéré garde son décodeur matériel : le suivant
        // ouvrirait moins vite, et le service de codecs finirait par refuser.
        nativePlayer?.dispose()
        nativePlayer = null
        nativeDiagnostics?.dispose()
        nativeDiagnostics = null
        // Le pont s'en va, le service reste : c'est tout l'intérêt.
        proximity?.dispose()
        proximity = null
        super.onDestroy()
    }
}
