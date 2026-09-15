import 'package:flutter/services.dart';

/// Accès au canal `neovibe/gallery` — la galerie du téléphone, lue par nous.
/// Voir `NativeGallery.kt`. Rien n'est écrit dans la galerie.
abstract final class NativeGallery {
  static const _channel = MethodChannel('neovibe/gallery');

  /// Une page de médias, les plus récents d'abord.
  static Future<List<GalleryEntry>> list({
    required int offset,
    required int limit,
  }) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'list',
      {'offset': offset, 'limit': limit},
    );
    return [
      for (final r in rows ?? const <Map<Object?, Object?>>[])
        GalleryEntry(
          uri: r['uri'] as String,
          isVideo: r['isVideo'] as bool,
          dateAdded: r['dateAdded'] as int,
          durationMs: r['durationMs'] as int?,
          width: r['width'] as int? ?? 0,
          height: r['height'] as int? ?? 0,
          mime: r['mime'] as String?,
        ),
    ];
  }

  /// Une vignette JPEG de [size] pixels de côté (le système la met en cache).
  static Future<Uint8List> thumbnail(String uri, {int size = 300}) async {
    final bytes = await _channel.invokeMethod<Uint8List>('thumbnail', {
      'uri': uri,
      'size': size,
    });
    if (bytes == null) throw StateError('vignette vide');
    return bytes;
  }

  /// Copie le média dans [dest] (notre cache), pour l'éditeur.
  static Future<void> copy(String uri, String dest) =>
      _channel.invokeMethod<String>('copy', {'uri': uri, 'dest': dest});
}

/// Un média de la galerie, tel que le `MediaStore` le décrit.
class GalleryEntry {
  const GalleryEntry({
    required this.uri,
    required this.isVideo,
    required this.dateAdded,
    this.durationMs,
    this.width = 0,
    this.height = 0,
    this.mime,
  });

  final String uri;
  final bool isVideo;

  /// Secondes depuis l'époque, comme le `MediaStore` la donne.
  final int dateAdded;
  final int? durationMs;
  final int width;
  final int height;
  final String? mime;

  @override
  bool operator ==(Object other) => other is GalleryEntry && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;
}
