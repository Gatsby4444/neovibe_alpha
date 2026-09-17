import 'package:flutter/services.dart';

/// Accès au canal `neovibe/gallery` — la galerie du téléphone, lue par nous.
/// Voir `NativeGallery.kt`. Rien n'est écrit dans la galerie.
abstract final class NativeGallery {
  static const _channel = MethodChannel('neovibe/gallery');

  /// **Les dossiers du téléphone** (Camera, Screenshots, WhatsApp…), celui
  /// qui a le média le plus récent d'abord.
  static Future<List<GalleryAlbum>> albums() async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'albums',
    );
    return [
      for (final r in rows ?? const <Map<Object?, Object?>>[])
        GalleryAlbum(
          id: r['id'] as String,
          name: r['name'] as String? ?? 'Sans nom',
          count: r['count'] as int? ?? 0,
          coverUri: r['coverUri'] as String?,
        ),
    ];
  }

  /// Une page de médias, les plus récents d'abord — de tout le téléphone, ou
  /// du seul dossier [bucketId], et du seul type [mediaType] (`image` ou
  /// `video`).
  static Future<List<GalleryEntry>> list({
    required int offset,
    required int limit,
    String? bucketId,
    String? mediaType,
  }) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'list',
      {
        'offset': offset,
        'limit': limit,
        'bucketId': ?bucketId,
        'mediaType': ?mediaType,
      },
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

/// **Un dossier de la galerie**, tel que le `MediaStore` le range : Camera,
/// Screenshots, WhatsApp Images… Le `MediaStore` les appelle des *buckets* ;
/// l'utilisateur, lui, dit « album ».
class GalleryAlbum {
  const GalleryAlbum({
    required this.id,
    required this.name,
    required this.count,
    this.coverUri,
  });

  final String id;
  final String name;
  final int count;

  /// Le média le plus récent du dossier — sa couverture.
  final String? coverUri;
}

/// **Ce qu'on regarde dans la galerie** : tout, un type, ou un dossier.
///
/// Un seul objet pour le filtre entier : le dossier et le type changeaient
/// autrefois séparément, et deux réglages d'une même chose finissent toujours
/// par se contredire. Il porte son égalité de valeur — c'est ce qui permet à
/// la cuisine de ne se recharger que s'il a **vraiment** changé.
class GalleryFilter {
  const GalleryFilter({this.album, this.mediaType});

  /// Tout le téléphone, photos et vidéos mêlées.
  static const tout = GalleryFilter();
  static const photos = GalleryFilter(mediaType: 'image');
  static const videos = GalleryFilter(mediaType: 'video');

  final GalleryAlbum? album;

  /// `image`, `video`, ou nul pour les deux.
  final String? mediaType;

  String get label =>
      album?.name ??
      switch (mediaType) {
        'image' => 'Photos',
        'video' => 'Vidéos',
        _ => 'Récent',
      };

  @override
  bool operator ==(Object other) =>
      other is GalleryFilter &&
      other.album?.id == album?.id &&
      other.mediaType == mediaType;

  @override
  int get hashCode => Object.hash(album?.id, mediaType);
}
