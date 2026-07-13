package com.neovibe.neovibe

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity (et non FlutterActivity) : CameraX exige un
// LifecycleOwner, que seule la variante Fragment fournit.
class MainActivity : FlutterFragmentActivity() {
    private var nativeCamera: NativeCamera? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeCamera = NativeCamera(
            this,
            flutterEngine.renderer,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }
}
