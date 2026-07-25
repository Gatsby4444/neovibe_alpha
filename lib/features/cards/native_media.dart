import 'package:flutter/services.dart';

/// Accès au canal `neovibe/media` — utilitaires média hors caméra.
///
/// Aujourd'hui : l'extraction d'une image de couverture d'une vidéo locale
/// (une vidéo ne se décode pas comme une image côté Dart, cf. « Invalid image
/// data »). Voir `NativeMedia.kt`.
abstract final class NativeMedia {
  static const _channel = MethodChannel('neovibe/media');

  /// Écrit dans [dest] une image JPEG de la première image-clé de [source].
  /// Renvoie `false` sur échec (fichier illisible, codec absent) — l'appelant
  /// retombe alors sur le repli visuel, ce n'est jamais bloquant.
  static Future<bool> videoThumbnail({
    required String source,
    required String dest,
    int width = 480,
  }) async {
    try {
      await _channel.invokeMethod<String>('videoThumbnail', {
        'source': source,
        'dest': dest,
        'width': width,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
