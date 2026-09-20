import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/cards/native_media.dart';
import '../supabase_providers.dart';
import 'content_face.dart';
import 'content_media_cache.dart';

/// **La vignette d'une face vidéo** (les Vibes vidéo dans la grille — Jay,
/// 2026-09-20 : *« dans les mini vibes il n'y a pas l'aperçu »*).
///
/// Une vidéo d'ALBUM a une couverture déposée à la publication. Une face de
/// Vibe n'en a pas — et en ajouter une à l'envoi n'aurait servi qu'aux
/// Vibes à venir. Ici, la couverture est **extraite sur l'appareil, une
/// fois**, de la vidéo scellée elle-même (locale pour les miennes, en flux
/// pour celles des autres — les mêmes blocs que le lecteur), puis
/// **rescellée avec la clé du contenu** dans le cache, sous la place de
/// couverture ([ContentSlot.poster]). Un seul chemin pour toutes les Vibes,
/// anciennes et nouvelles ; jamais un pixel en clair sur le disque.
///
/// Rend les octets JPEG ; lève si la vidéo ne se lit pas.
final videoPosterProvider = FutureProvider.family<Uint8List, ContentFace>((
  ref,
  spec,
) async {
  final media = await ref.watch(contentFaceProvider(spec).future);
  final key = media.mediaKey;
  if (!media.isVideo || key == null) {
    throw StateError('pas une vidéo scellée');
  }
  final me = ref.watch(currentUserIdProvider);
  final cache = ref.watch(contentMediaCacheProvider);
  final poster = await cache.generatedPosterFile(
    spec.contentId,
    slot: spec.slot,
    own: spec.ownerId == me,
  );
  if (!await poster.exists()) {
    final ok = await NativeMedia.sealedPoster(
      sealed: media.sealedVideo?.path,
      url: media.sealedVideo == null ? media.videoUrl : null,
      cachePath: media.sealedVideo == null ? media.videoCachePath : null,
      key: key,
      dest: poster.path,
    );
    if (!ok) throw StateError('natif absent');
  }
  final bytes = await NativeMedia.readAll(sealed: poster.path, key: key);
  if (bytes == null) throw StateError('natif absent');
  return bytes;
});
