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

  /// Sonde double flux en Camera2 BRUT : ouvre les deux caméras de force,
  /// sans passer par la déclaration `getConcurrentCameraIds()` d'Android
  /// (que CameraX respecte, et qui est un faux négatif fréquent). Dit si le
  /// matériel accepte RÉELLEMENT deux flux simultanés.
  static Future<Map<String, dynamic>> probeDual() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('probeDual');
    return res ?? const {};
  }

  /// Image quelconque → **face de card prête** (rotation EXIF appliquée,
  /// recadrage 9:16 centré, format unifié 900×1600, JPEG), fait en natif.
  ///
  /// Le même travail en Dart (décodage + `PictureRecorder` + encodage **PNG**)
  /// prenait plusieurs secondes pour un Oneshot — assez pour que l'utilisateur
  /// ait le temps de changer de mode pendant le traitement (bug du 2026-07-14).
  static Future<File> normalize(File source) async {
    final res = await _channel
        .invokeMapMethod<String, dynamic>('normalize', {'path': source.path})
        .timeout(const Duration(seconds: 10));
    return File(res!['path'] as String);
  }

  /// Journal caméra PERSISTANT (fichier natif, survit aux crashes — voir
  /// CamLog.kt). Le Dart et le natif écrivent au même endroit : une seule
  /// trace à copier pour diagnostiquer.
  static Future<void> log(String message) async {
    try {
      await _channel.invokeMethod('log', {'message': message});
    } catch (_) {
      // Journal indisponible : ne doit jamais faire échouer l'appelant.
    }
  }

  static Future<String> readLog() async {
    try {
      return await _channel.invokeMethod<String>('readLog') ?? '';
    } catch (e) {
      return 'Journal illisible : $e';
    }
  }

  static Future<void> clearLog() async {
    try {
      await _channel.invokeMethod('clearLog');
    } catch (_) {}
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
    // Borné : l'ouverture attend la fermeture réelle d'un éventuel double flux
    // (côté natif), mais elle ne doit jamais bloquer l'écran indéfiniment.
    final res = await _channel
        .invokeMapMethod<String, dynamic>('open', {
          'back': back,
          'audio': audio,
        })
        .timeout(const Duration(seconds: 10));
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
    final res = await _channel
        .invokeMapMethod<String, dynamic>('takePicture')
        .timeout(const Duration(seconds: 8));
    return File(res!['path'] as String);
  }

  Future<void> startVideo({required bool audio}) =>
      _channel.invokeMethod('startVideo', {'audio': audio});

  Future<File> stopVideo() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('stopVideo');
    return File(res!['path'] as String);
  }

  /// Le double flux a échoué depuis le lancement de l'app : on ne le retente
  /// PAS avant le prochain démarrage (décision Jay : un réessai par session).
  /// Sonder le matériel a un coût réel — un échec peut laisser le service
  /// caméra d'Android hors service jusqu'au redémarrage.
  static var dualFailedThisSession = false;

  /// Le service caméra d'Android répond-il encore ? (Après certains échecs, il
  /// tombe : `cameraIdList` devient vide et plus rien ne s'ouvre.)
  static Future<bool> isCameraServiceAlive() async {
    try {
      return await _channel.invokeMethod<bool>('isCameraServiceAlive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ouvre le double flux (Oneshot). Lève [DualUnsupportedException] si
  /// l'appareil refuse — l'appelant repasse en vue simple.
  ///
  /// Toujours borné dans le temps : une caméra qui ne répond pas ne doit
  /// JAMAIS laisser l'écran en chargement infini (retour Jay, v0.8.5).
  Future<void> openDual() async {
    try {
      final res = await _channel
          .invokeMapMethod<String, dynamic>('openDual')
          .timeout(const Duration(seconds: 10));
      dualBackTextureId = res?['backTextureId'] as int?;
      dualFrontTextureId = res?['frontTextureId'] as int?;
      dualActive = true;
      textureId = null;
      notifyListeners();
    } on TimeoutException {
      dualFailedThisSession = true;
      throw const DualUnsupportedException('La caméra ne répond pas (10 s)');
    } on PlatformException catch (e) {
      dualFailedThisSession = true;
      if (e.code == 'DUAL_UNSUPPORTED') {
        throw DualUnsupportedException(e.message);
      }
      rethrow;
    }
  }

  /// Les deux photos d'un coup : arrière = recto, avant = verso. En double
  /// flux, ce sont les DERNIÈRES IMAGES REÇUES des deux capteurs — donc
  /// instantané, et vraiment simultané.
  Future<({File back, File front})> takeDualPictures() async {
    final res = await _channel
        .invokeMapMethod<String, dynamic>('takeDualPictures')
        .timeout(const Duration(seconds: 8));
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

  /// ÉTAPE 1 du rendu GPU — aperçu OpenGL d'UNE caméra (écran de test dev,
  /// isolé du flux de capture réel). Rotation + miroir sont faits dans le
  /// shader → côté Dart, `mirror: false` et rotation 0. Voir Camera2Gl.kt.
  int? glTextureId;

  Future<void> openGlPreview({
    required bool back,
    int rotation = 90,
    bool mirror = false,
  }) async {
    final res = await _channel
        .invokeMapMethod<String, dynamic>('openGlPreview', {
          'back': back,
          'rotation': rotation,
          'mirror': mirror,
        })
        .timeout(const Duration(seconds: 10));
    glTextureId = res?['textureId'] as int?;
    notifyListeners();
  }

  Future<void> closeGlPreview() async {
    try {
      await _channel.invokeMethod('closeGlPreview');
    } catch (_) {}
    glTextureId = null;
    notifyListeners();
  }

  /// ÉTAPE 2 du rendu GPU — les DEUX caméras en OpenGL, chacune sur sa texture.
  int? glBackTextureId;
  int? glFrontTextureId;

  Future<void> openGlDual() async {
    final res = await _channel
        .invokeMapMethod<String, dynamic>('openGlDual')
        .timeout(const Duration(seconds: 12));
    glBackTextureId = res?['backTextureId'] as int?;
    glFrontTextureId = res?['frontTextureId'] as int?;
    notifyListeners();
  }

  Future<void> closeGlDual() async {
    try {
      await _channel.invokeMethod('closeGlDual');
    } catch (_) {}
    glBackTextureId = null;
    glFrontTextureId = null;
    notifyListeners();
  }

  Future<void> close() async {
    try {
      // La réponse native n'arrive qu'une fois le matériel RENDU (attente des
      // callbacks onClosed) : c'est ce qui permet de rouvrir sans casser le
      // service caméra. Bornée quand même.
      await _channel.invokeMethod('close').timeout(const Duration(seconds: 6));
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
