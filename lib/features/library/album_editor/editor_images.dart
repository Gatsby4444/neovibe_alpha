import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import '../../cards/native_media.dart';
import 'album_draft.dart';

/// **Les images décodées de l'éditeur**, tenues à un seul endroit : la source
/// d'un média en grand (pour le shader de l'aperçu), en petit (pour les puces
/// de filtres), et les images d'autocollants. Chaque image est décodée une
/// fois, bornée en taille, et libérée quand l'éditeur se ferme.
///
/// Pour une **vidéo**, « l'image » est une image extraite au début du morceau
/// rogné : les puces de filtres ont besoin d'une photo, pas d'un lecteur.
class EditorImages {
  final _full = <String, Future<ui.Image>>{};
  final _small = <String, Future<ui.Image>>{};
  final _stickers = <String, Future<ui.Image>>{};
  final _ready = <String, ui.Image>{};

  /// Le grand côté de la source décodée pour l'aperçu : assez pour un écran
  /// de téléphone, jamais les 12 Mpx d'origine (≈ 10 Mo de pixels au lieu de
  /// 48).
  static const fullSide = 1600;
  static const smallSide = 256;
  static const stickerSide = 640;

  /// L'image si elle est déjà décodée — l'aperçu peint sans attendre.
  ui.Image? ready(String key) => _ready[key];

  Future<ui.Image> full(AlbumDraftMedia m) =>
      _full.putIfAbsent(m.id, () => _decodeMedia(m, fullSide, 'full:${m.id}'));

  Future<ui.Image> small(AlbumDraftMedia m) => _small.putIfAbsent(
    m.id,
    () => _decodeMedia(m, smallSide, 'small:${m.id}'),
  );

  Future<ui.Image> sticker(String path) => _stickers.putIfAbsent(
    path,
    () => _decodeFile(File(path), stickerSide, 'sticker:$path'),
  );

  ui.Image? stickerReady(String path) => _ready['sticker:$path'];

  /// Un média a changé de rognage (vidéo) : son image extraite est périmée.
  void invalidate(AlbumDraftMedia m) {
    _full.remove(m.id);
    _small.remove(m.id);
    _ready.remove('full:${m.id}')?.dispose();
    _ready.remove('small:${m.id}')?.dispose();
  }

  Future<ui.Image> _decodeMedia(AlbumDraftMedia m, int side, String key) async {
    File source = m.source;
    if (m.isVideo) {
      final temp = await getTemporaryDirectory();
      final dest = File('${temp.path}/album_frame_${m.id}_$side.jpg');
      final ok = await NativeMedia.videoThumbnail(
        source: m.source.path,
        dest: dest.path,
        width: side,
        atMs: m.effectiveTrim.startMs,
      );
      if (!ok) throw StateError('image de la vidéo impossible à extraire');
      source = dest;
    }
    return _decodeFile(source, side, key);
  }

  Future<ui.Image> _decodeFile(File file, int side, String key) async {
    final img = await decodeBounded(file, side);
    _ready[key] = img;
    return img;
  }

  /// Décode [file] avec son grand côté borné à [side] pixels. Le résultat
  /// appartient à l'appelant (à libérer).
  static Future<ui.Image> decodeBounded(File file, int side) async {
    final bytes = await file.readAsBytes();
    // Les dimensions se lisent sans décoder (`ImageDescriptor`), puis on borne
    // le GRAND côté : `targetWidth` seul étirerait la hauteur d'un portrait
    // bien au-delà de ce qu'on veut en mémoire.
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    final codec = w >= h
        ? await descriptor.instantiateCodec(targetWidth: side.clamp(1, w))
        : await descriptor.instantiateCodec(targetHeight: side.clamp(1, h));
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  void dispose() {
    for (final img in _ready.values) {
      img.dispose();
    }
    _ready.clear();
    _full.clear();
    _small.clear();
    _stickers.clear();
  }
}
