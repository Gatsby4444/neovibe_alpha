import 'dart:async';
import 'dart:io';

import '../../../core/drafts/draft_store.dart';
import '../../../core/utils/ids.dart';
import '../../cards/native_media.dart';
import 'album_draft.dart';
import 'album_draft_codec.dart';
import 'overlay_model.dart';

/// **Le gardien d'un brouillon de publication** (Brouillons, 2026-09-20).
///
/// Il fait deux choses, et l'éditeur n'a pas à savoir comment :
///
/// - **adopter les fichiers** : un média importé, une image d'autocollant
///   arrivent de `work/` (balayé au démarrage) ou d'un dossier temporaire ;
///   ils sont **déplacés** dans le dossier du brouillon (un renommage, pas
///   une copie — instantané même pour une vidéo) et le média est réécrit
///   avec son nouveau chemin. À faire **avant** que l'éditeur ne les
///   décode, sinon il décoderait un chemin qui n'existe plus ;
/// - **écrire le brouillon** à chaque retouche ([schedule], regroupé sur
///   800 ms) et le retirer quand la publication part ([delete]).
///
/// Un même gardien suit la publication de l'éditeur à la légende : le
/// brouillon garde son identifiant, et sa liste ne montre qu'une entrée.
class AlbumDraftKeeper {
  AlbumDraftKeeper(this._store, {String? id}) : id = id ?? newUuid();

  final DraftStore _store;
  final String id;
  Timer? _timer;
  AlbumDraft? _pending;
  String _step = 'edit';
  Future<void>? _writing;
  var _deleted = false;

  Future<Directory> get dir => _store.dir(id);

  /// Les médias, lus depuis le dossier du brouillon. Idempotent : un fichier
  /// déjà dedans n'est pas touché.
  Future<List<AlbumDraftMedia>> adoptMedia(List<AlbumDraftMedia> media) async {
    final d = await dir;
    final out = <AlbumDraftMedia>[];
    for (final m in media) {
      final ext = m.isVideo ? 'mp4' : 'jpg';
      final moved = await _adopt(m.source, d, 'media_${m.id}.$ext');
      out.add(identical(moved, m.source) ? m : m.withSource(moved));
    }
    return out;
  }

  /// Un autocollant image, lu depuis le dossier du brouillon.
  Future<StickerOverlay> adoptSticker(StickerOverlay s) async {
    final path = s.imagePath;
    if (path == null) return s;
    final moved = await _adopt(File(path), await dir, 'sticker_${s.id}.jpg');
    if (moved.path == path) return s;
    return StickerOverlay(
      id: s.id,
      imagePath: moved.path,
      cx: s.cx,
      cy: s.cy,
      scale: s.scale,
      rotation: s.rotation,
    );
  }

  Future<File> _adopt(File source, Directory d, String name) async {
    if (source.path.startsWith(d.path)) return source;
    final target = File('${d.path}${Platform.pathSeparator}$name');
    try {
      return await source.rename(target.path);
    } on FileSystemException {
      // Pas le même système de fichiers (une prise de l'appareil photo dans
      // le cache) : on copie, puis on efface l'original.
      final copied = await source.copy(target.path);
      try {
        await source.delete();
      } catch (_) {}
      return copied;
    }
  }

  /// À chaque retouche : le brouillon sera écrit dans 800 ms — ou avec la
  /// retouche suivante, si elle arrive avant.
  void schedule(AlbumDraft draft, {required String step}) {
    if (_deleted) return;
    _pending = draft;
    _step = step;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () => unawaited(flush()));
  }

  /// Écrit tout de suite ce qui attend (avant de quitter l'écran).
  Future<void> flush() async {
    _timer?.cancel();
    final draft = _pending;
    if (draft == null || _deleted) return;
    _pending = null;
    // Une écriture à la fois : la suivante attend la précédente.
    await _writing;
    _writing = _write(draft, _step);
    await _writing;
  }

  Future<void> _write(AlbumDraft draft, String step) async {
    if (draft.media.isEmpty) return;
    try {
      final cover = await _cover(draft);
      final photos = draft.media.where((m) => !m.isVideo).length;
      final videos = draft.media.length - photos;
      await _store.save(
        Draft(
          id: id,
          kind: draft.flow ? DraftKind.flow : DraftKind.publication,
          step: step,
          updatedAt: DateTime.now(),
          payload: AlbumDraftCodec.toJson(draft),
          cover: cover,
          summary: [
            if (photos > 0) '$photos photo${photos > 1 ? 's' : ''}',
            if (videos > 0) '$videos vidéo${videos > 1 ? 's' : ''}',
          ].join(', '),
        ),
      );
    } catch (_) {
      // Un brouillon qui ne s'écrit pas n'arrête pas l'édition : c'est un
      // filet, pas une condition.
    }
  }

  /// L'image de la liste : la photo elle-même, ou une image de la vidéo.
  Future<String?> _cover(AlbumDraft draft) async {
    final first = draft.media.first;
    if (!first.isVideo) return first.source.path;
    final file = File(
      '${(await dir).path}${Platform.pathSeparator}cover_${first.id}.jpg',
    );
    if (await file.exists()) return file.path;
    final ok = await NativeMedia.videoThumbnail(
      source: first.source.path,
      dest: file.path,
      width: 320,
      atMs: first.effectiveTrim.coverMs,
    );
    return ok ? file.path : null;
  }

  /// La publication est partie (ou l'utilisateur a jeté le brouillon) : le
  /// dossier et ses fichiers s'effacent.
  Future<void> delete() async {
    _deleted = true;
    _timer?.cancel();
    _pending = null;
    await _writing;
    await _store.delete(id);
  }
}
