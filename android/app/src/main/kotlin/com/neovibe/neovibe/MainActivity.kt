package com.neovibe.neovibe

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity (et non FlutterActivity) : CameraX exige un
// LifecycleOwner, que seule la variante Fragment fournit.
class MainActivity : FlutterFragmentActivity() {
    private var nativeCamera: NativeCamera? = null
    private var nativeBle: NativeBle? = null
    private var nativeMedia: NativeMedia? = null

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
        nativeBle = NativeBle(this, flutterEngine.dartExecutor.binaryMessenger)
        nativeMedia = NativeMedia(flutterEngine.dartExecutor.binaryMessenger)
    }
}
