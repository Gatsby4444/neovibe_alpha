import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../library/album_editor/album_export.dart';
import 'vibe_edit_draft.dart';

/// Les deux faces d'une Vibe, prêtes à l'envoi.
typedef VibeFaces = ({File front, File? back});

/// Rend les faces d'un [VibeEditDraft] en fichiers — **par l'export des
/// Flows** ([AlbumExport]) : le même shader pour une photo, le même
/// transcodeur pour une vidéo, au format 9:16. Ce que l'aperçu montre est ce
/// qui part.
///
/// ⚠️ **Une face non retouchée n'est pas ré-exportée** : son fichier de
/// capture part tel quel. Retranscoder une vidéo qu'on n'a pas touchée lui
/// coûterait une génération de compression et une bonne partie d'une minute ;
/// ré-encoder une photo, sa netteté.
abstract final class VibeExport {
  static Future<VibeFaces> render(
    VibeEditDraft draft, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/vibe_edit');
    if (!await dir.exists()) await dir.create(recursive: true);

    // La progression : la moitié par face quand il y en a deux à rendre.
    final toRender = [if (draft.frontEdited) true, if (draft.backEdited) false];
    var done = 0;
    Future<File> rendre(bool isFront) async {
      final m = draft.face(front: isFront);
      final out = await AlbumExport.render(
        m,
        VibeEditDraft.aspect,
        dir,
        maxVideoMs: VibeEditDraft.maxVideoMs,
        onProgress: (p) => onProgress?.call((done + p) / toRender.length),
      );
      done += 1;
      onProgress?.call(done / toRender.length);
      return out.file;
    }

    final front = draft.frontEdited ? await rendre(true) : draft.front.source;
    final back = draft.back == null
        ? null
        : draft.backEdited
        ? await rendre(false)
        : draft.back!.source;
    return (front: front, back: back);
  }
}
