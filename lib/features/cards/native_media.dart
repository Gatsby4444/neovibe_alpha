import 'package:flutter/services.dart';

/// Accès au canal `neovibe/media` — utilitaires média hors caméra.
///
/// Deux capacités : l'extraction d'une image de couverture d'une vidéo locale
/// (une vidéo ne se décode pas comme une image côté Dart, cf. « Invalid image
/// data »), et la mise en tête de l'index MP4. Voir `NativeMedia.kt`.
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

  /// Déplace l'index d'un MP4 (`moov`) **en tête de fichier**, pour qu'un
  /// lecteur distant puisse décoder dès les premiers octets reçus au lieu
  /// d'aller d'abord chercher la fin.
  ///
  /// Renvoie le verdict natif (`MOVED`, `ALREADY_FAST`, `UNSUPPORTED`,
  /// `FAILED`) à seule fin de journalisation : **aucun n'est bloquant**. Une
  /// vidéo dont l'index n'a pas pu bouger reste parfaitement lisible, elle
  /// démarre seulement moins vite. Voir `Mp4FastStart.kt`.
  static Future<String> fastStart(String path) async {
    try {
      return await _channel.invokeMethod<String>('fastStart', {'path': path}) ??
          'FAILED';
    } on PlatformException {
      return 'FAILED';
    } on MissingPluginException {
      return 'FAILED';
    }
  }
}
