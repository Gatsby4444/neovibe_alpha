import 'dart:io';

import 'media_export.dart';
import 'vibe_edit_draft.dart';
import '../../../core/work_dir.dart';

/// Les deux faces d'une Vibe, prêtes à l'envoi.
typedef VibeFaces = ({File front, File? back});

/// Rend les faces d'un [VibeEditDraft] en fichiers ([MediaExport]) : le
/// shader de l'aperçu pour une photo, le transcodeur natif pour une vidéo,
/// au format 9:16. Ce que l'aperçu montre est ce qui part.
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
    final dir = await WorkDir.named('vibe_edit');

    // La progression : la moitié par face quand il y en a deux à rendre.
    final toRender = [if (draft.frontEdited) true, if (draft.backEdited) false];
    var done = 0;
    Future<File> rendre(bool isFront) async {
      final m = draft.face(front: isFront);
      final out = await MediaExport.render(
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
