import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pilote Dart de la couche caméra native NeoVibe (voir NativeCamera.kt).
/// Remplace le plugin `camera` (décision Jay 2026-07-13) et débloque le
/// double flux Oneshot, la bascule caméra EN COURS de vidéo (Mono) et
/// FLAG_SECURE.
class NativeCameraController extends ChangeNotifier {
  NativeCameraController() {
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  static const _channel = MethodChannel('neovibe/camera');

  /// Texture principale (mode simple).
  int? textureId;

  /// Textures du double flux Oneshot.
  int? dualBackTextureId;
  int? dualFrontTextureId;

  /// Infos d'affichage par flux (résolution capteur + rotation à appliquer).
  final Map<String, NativePreviewInfo> previews = {};

  var lensBack = true;
  var dualActive = false;
  var _disposed = false;

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    if (call.method == 'previewInfo' && !_disposed) {
      final args = (call.arguments as Map).cast<String, dynamic>();
      previews[args['key'] as String] = NativePreviewInfo(
        width: args['width'] as int,
        height: args['height'] as int,
        rotationDegrees: args['rotation'] as int,
      );
      notifyListeners();
    }
    return null;
  }

  /// Ce que l'appareil déclare RÉELLEMENT sur le double flux : ce que CameraX
  /// annonce, ce que le pilote Camera2 annonce (source de vérité matérielle),
  /// le modèle, et la dernière erreur de bind. Sert le HUD de diagnostic.
  static Future<CameraCapabilities> capabilities() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      return CameraCapabilities(
        concurrent: res?['concurrent'] as bool? ?? false,
        cameraXCombos: res?['cameraXCombos'] as int? ?? 0,
        camera2Combos: res?['camera2Combos'] as int? ?? 0,
        device: res?['device'] as String? ?? '?',
        sdk: res?['sdk'] as int? ?? 0,
        lastDualError: res?['lastDualError'] as String?,
      );
    } catch (e) {
      return CameraCapabilities(
        concurrent: false,
        cameraXCombos: 0,
        camera2Combos: 0,
        device: '?',
        sdk: 0,
        lastDualError: e.toString(),
      );
    }
  }

  /// FLAG_SECURE global : screenshots bloqués, écran noir en partage.
  /// Désactivable via l'option développeur (consigne Jay).
  static Future<void> setSecure(bool on) async {
    try {
      await _channel.invokeMethod('setSecure', {'on': on});
    } catch (_) {
      // iOS/desktop : pas de FLAG_SECURE — silencieux.
    }
  }

  Future<void> open({required bool back, required bool audio}) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('open', {
      'back': back,
      'audio': audio,
    });
    lensBack = back;
    dualActive = false;
    textureId = res?['textureId'] as int?;
    notifyListeners();
  }

  /// Bascule avant/arrière. Pendant une vidéo (enregistrement persistant
  /// natif), l'enregistrement CONTINUE à travers la bascule.
  Future<void> switchLens() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('switchLens');
    lensBack = res?['back'] as bool? ?? !lensBack;
    notifyListeners();
  }

  Future<File> takePicture() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('takePicture');
    return File(res!['path'] as String);
  }

  Future<void> startVideo({required bool audio}) =>
      _channel.invokeMethod('startVideo', {'audio': audio});

  Future<File> stopVideo() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('stopVideo');
    return File(res!['path'] as String);
  }

  /// Ouvre le double flux (Oneshot). Lève [DualUnsupportedException] si
  /// l'appareil refuse — l'appelant repasse en vue simple.
  Future<void> openDual() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('openDual');
      dualBackTextureId = res?['backTextureId'] as int?;
      dualFrontTextureId = res?['frontTextureId'] as int?;
      dualActive = true;
      textureId = null;
      notifyListeners();
    } on PlatformException catch (e) {
      if (e.code == 'DUAL_UNSUPPORTED') {
        throw DualUnsupportedException(e.message);
      }
      rethrow;
    }
  }

  /// Les deux photos d'un coup : arrière = recto, avant = verso.
  Future<({File back, File front})> takeDualPictures() async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'takeDualPictures',
    );
    return (
      back: File(res!['back'] as String),
      front: File(res['front'] as String),
    );
  }

  /// Vidéo double simultanée (Oneshot vidéo). Lève
  /// [DualUnsupportedException] si le matériel refuse le double
  /// enregistrement — l'appelant retombe en photo seule.
  Future<void> startDualVideo({required bool audio}) async {
    try {
      await _channel.invokeMethod('startDualVideo', {'audio': audio});
    } on PlatformException catch (e) {
      if (e.code == 'DUAL_VIDEO_UNSUPPORTED') {
        throw DualUnsupportedException(e.message);
      }
      rethrow;
    }
  }

  Future<({File back, File front})> stopDualVideo() async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'stopDualVideo',
    );
    return (
      back: File(res!['back'] as String),
      front: File(res['front'] as String),
    );
  }

  Future<void> close() async {
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
    textureId = null;
    dualBackTextureId = null;
    dualFrontTextureId = null;
    dualActive = false;
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }
}

class NativePreviewInfo {
  const NativePreviewInfo({
    required this.width,
    required this.height,
    required this.rotationDegrees,
  });
  final int width;
  final int height;

  /// Rotation à appliquer à l'affichage (fournie par CameraX pour ce bind).
  final int rotationDegrees;
}

class DualUnsupportedException implements Exception {
  const DualUnsupportedException([this.reason]);

  /// Message brut de CameraX (affiché dans le HUD développeur).
  final String? reason;

  @override
  String toString() => reason ?? 'Double flux non supporté';
}

/// Diagnostic du double flux, tel que l'appareil le déclare.
class CameraCapabilities {
  const CameraCapabilities({
    required this.concurrent,
    required this.cameraXCombos,
    required this.camera2Combos,
    required this.device,
    required this.sdk,
    this.lastDualError,
  });

  /// CameraX annonce au moins une combinaison de caméras concurrentes.
  final bool concurrent;
  final int cameraXCombos;

  /// Combinaisons annoncées par le pilote Camera2 (-1 : Android < 11).
  final int camera2Combos;
  final String device;
  final int sdk;
  final String? lastDualError;
}

/// Aperçu d'un flux natif SANS distorsion : rotation portrait + miroir pour
/// la frontale, recadré « cover » dans le cadre du parent (même WYSIWYG que
/// l'ancien aperçu — fix distorsion conservé).
class NativeCameraPreview extends StatelessWidget {
  const NativeCameraPreview({
    super.key,
    required this.textureId,
    required this.info,
    required this.mirror,
  });

  final int textureId;
  final NativePreviewInfo? info;

  /// Caméra frontale : effet miroir de l'aperçu (comme un vrai miroir),
  /// la photo elle-même n'est pas inversée (comportement inchangé).
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    final preview = info;
    if (preview == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final quarterTurns = (preview.rotationDegrees ~/ 90) % 4;
    final rotated = quarterTurns.isOdd;
    final displayWidth = rotated ? preview.height : preview.width;
    final displayHeight = rotated ? preview.width : preview.height;
    Widget child = SizedBox(
      width: displayWidth.toDouble(),
      height: displayHeight.toDouble(),
      child: RotatedBox(
        quarterTurns: quarterTurns,
        child: Texture(textureId: textureId),
      ),
    );
    if (mirror) {
      child = Transform.scale(scaleX: -1, child: child);
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: child,
      ),
    );
  }
}
