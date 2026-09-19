import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_media_cache.dart';
import '../../../core/content/own_keys.dart';
import '../../../core/crypto/chunked_seal.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../../core/publish/publish_bridge.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/ids.dart';
import '../../cards/native_media.dart';
import '../library_repository.dart';
import 'album_draft.dart';
import 'album_export.dart';

/// **Une publication déposée à la file native**, et les deux gestes qui
/// restent à l'utilisateur : « Publier » ([release]) ou revenir en arrière
/// ([cancel]).
class PreparedPublication {
  PreparedPublication._(this.id, this._ref);

  final String id;
  final Ref _ref;

  /// « Publier » : la légende et les droits partent au service, qui inscrit
  /// la publication dès que tout est déposé. À partir de là, la grille la
  /// montre avec son avancement.
  Future<void> release(AlbumDraft draft) {
    final caption = draft.caption.trim();
    return PublishBridge.instance.release(
      id,
      caption: caption.isEmpty ? null : caption,
      captionFont: draft.captionFont?.name,
      isPublic: draft.isPublic,
      shareable: draft.shareable,
      saveable: draft.saveable,
    );
  }

  /// Retour en arrière avant « Publier » : le service arrête, efface ce qui
  /// est au coffre et son dossier ; la clé locale, qui ne déchiffrerait plus
  /// rien, part avec.
  Future<void> cancel() async {
    await PublishBridge.instance.cancel(id);
    await _ref.read(ownKeyStoreProvider).remove(id);
  }
}

/// **Ce que l'app fait encore d'une publication, à « Suivant »** — le reste
/// est au service natif (Jay, 2026-09-19 : *« la publication est une file
/// NATIVE et persistante »*).
///
/// 1. rend les **photos** avec le shader de l'aperçu (seul Flutter le sait
///    faire : ce que l'aperçu affiche est ce qui sort) ;
/// 2. rend le **calque** des vidéos (textes, autocollants) en PNG, et calcule
///    les **paramètres** de leur transcodage ([AlbumExport.videoSpec]) ;
/// 3. copie la source de chaque vidéo dans le dossier de la publication —
///    la copie de la galerie vit sous `work/`, balayé au prochain démarrage,
///    et l'éditeur en a encore besoin si l'utilisateur revient en arrière ;
/// 4. écrit la **couverture** que la grille montrera pendant l'envoi ;
/// 5. tire la **clé**, la range dans `own_keys` (la publication sera lisible
///    dès qu'elle apparaît), calcule où chaque scellé ira dans le cache de
///    mes contenus ;
/// 6. **dépose** le tout. Le service commence aussitôt, pendant la légende.
///
/// Tout ce qui est calculé ici l'est UNE fois, en Dart, avec les mêmes
/// fonctions que l'éditeur de Vibes : le natif ne connaît ni le cadrage ni
/// les filtres, il reçoit des nombres.
class PublishPreparer {
  PublishPreparer(this.ref);
  final Ref ref;

  Future<PreparedPublication> start(AlbumDraft draft) async {
    final me = ref.read(currentUserIdProvider)!;
    final bridge = PublishBridge.instance;
    final itemId = newUuid();
    final mediaKey = await ChunkedSeal.newKey();
    final dirPath = await bridge.jobDir(itemId);
    if (dirPath == null) throw StateError('file de publication indisponible');
    final dir = Directory(dirPath);
    final cache = ref.read(contentMediaCacheProvider);
    final (outW, outH) = AlbumExport.outputSize(draft.aspect);

    final media = <Map<String, Object?>>[];
    final ownCache = <String, String>{};
    String? cover;

    Map<String, Object?> fichier(int contentSlot, String clear, String ext) => {
      'contentSlot': contentSlot,
      'clear': clear,
      'sealed': '$clear.seal',
      'storagePath':
          '$me/${itemId}_${contentSlot >= 100 ? '${contentSlot - 100}_poster' : '$contentSlot'}.$ext',
      'isSealed': false,
      'uploadUrl': null,
      'uploaded': false,
    };

    for (var slot = 0; slot < draft.media.length; slot++) {
      final m = draft.media[slot];
      ownCache['$slot'] = await cache.ownPath(itemId, slot: slot);
      if (!m.isVideo) {
        final file = await AlbumExport.renderPhoto(m, draft.aspect, dir);
        if (slot == 0) cover = (await file.copy('${dir.path}/cover.jpg')).path;
        media.add({
          'slot': slot,
          'isVideo': false,
          'width': outW,
          'height': outH,
          'source': null,
          'transcode': null,
          'coverMs': 0,
          'maxDurationMs': 0,
          'durationMs': null,
          'file': fichier(slot, file.path, 'jpg'),
          'poster': null,
        });
      } else {
        final source = await m.source.copy('${dir.path}/album_${m.id}_src.mp4');
        final overlay = await AlbumExport.renderOverlay(m, draft.aspect, dir);
        final trim = m.effectiveTrim;
        final posterSlot = ContentSlot.poster(slot);
        ownCache['$posterSlot'] = await cache.ownPath(itemId, slot: posterSlot);
        if (slot == 0) {
          final c = '${dir.path}/cover.jpg';
          final ok = await NativeMedia.videoThumbnail(
            source: m.source.path,
            dest: c,
            width: 480,
            atMs: trim.coverMs,
          );
          if (ok) cover = c;
        }
        media.add({
          'slot': slot,
          'isVideo': true,
          'width': outW,
          'height': outH,
          'source': source.path,
          'transcode': AlbumExport.videoSpec(
            m,
            draft.aspect,
            overlayPath: overlay,
          ),
          'coverMs': trim.coverMs - trim.startMs,
          'maxDurationMs': draft.maxVideoMs,
          'durationMs': null,
          'file': fichier(slot, '${dir.path}/album_${m.id}.mp4', 'mp4'),
          'poster': fichier(
            posterSlot,
            '${dir.path}/album_${m.id}_poster.jpg',
            'jpg',
          ),
        });
      }
    }

    // La clé de MES contenus reste locale, comme pour une Vibe.
    await ref.read(ownKeyStoreProvider).put(itemId, mediaKey);

    final job = <String, Object?>{
      'id': itemId,
      'ownerId': me,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'kind': kindDuContenu(draft.media.map((m) => m.isVideo)).dbValue,
      'aspectW': draft.aspect.w,
      'aspectH': draft.aspect.h,
      'mediaKey': mediaKey,
      'media': media,
      'ownCache': ownCache,
      'cover': cover,
      'phase': 'preparing',
      'error': null,
      'attempts': 0,
      'progress': 0.0,
    };
    await bridge.enqueue(job);
    AppLog.instance.app(
      'Publication déposée — ${itemId.substring(0, 8)} · ${media.length} média(s)',
    );
    return PreparedPublication._(itemId, ref);
  }
}

final publishPreparerProvider = Provider((ref) => PublishPreparer(ref));
