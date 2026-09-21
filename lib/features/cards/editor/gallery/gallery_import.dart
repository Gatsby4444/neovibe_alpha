import 'dart:io';

import '../../../../core/utils/ids.dart';
import '../../../../core/work_dir.dart';
import 'native_gallery.dart';

/// **De la galerie au dossier de travail** : copie un média du téléphone dans
/// notre cache, d'où l'app peut le lire (un autocollant image, aujourd'hui).
///
/// Le sondage, la découpe des vidéos longues et l'appareil photo du système
/// qui vivaient ici servaient à l'éditeur d'album, sorti du MVP le
/// 2026-09-21. Le jour où la Vibe accepte des vidéos importées, c'est ici
/// qu'on les ramènera.
abstract final class GalleryImport {
  /// Copie [entry] dans le dossier de travail de l'app et rend le fichier.
  static Future<File> copy(GalleryEntry entry) async {
    final work = await WorkDir.named('gallery');
    final ext = entry.isVideo ? 'mp4' : 'jpg';
    final dest = File('${work.path}/gallery_${newUuid()}.$ext');
    await NativeGallery.copy(entry.uri, dest.path);
    return dest;
  }
}
