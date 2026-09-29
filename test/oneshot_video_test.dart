import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/drafts/draft_store.dart';
import 'package:neovibe/features/cards/oneshot_video.dart';
import 'package:neovibe/features/cards/vibe_draft_keeper.dart';

/// **La fin d'une vidéo Oneshot** (`terminerVideoOneshot`), avec une fausse
/// caméra et le VRAI gardien de brouillon — dont l'adoption DÉPLACE les
/// fichiers.
///
/// Panne vue par Jay le 2026-09-30 : « Vidéo impossible :
/// PathNotFoundException … nv_gl_video_glBack_….mp4 ». Le journal relisait
/// les chemins d'avant l'adoption, levait, et toute vidéo Oneshot avortait
/// (depuis v0.9.227). Ces essais passent au ROUGE si la faute revient
/// (contre-essai fait le 2026-09-30).
void main() {
  late Directory tmp;
  late VibeDraftKeeper keeper;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nv_oneshot_');
    keeper = VibeDraftKeeper(
      DraftStore(root: Directory('${tmp.path}/brouillons')),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<({File back, File front})> fausseCamera() async => (
    back: File('${tmp.path}/nv_gl_video_glBack_1.mp4')
      ..writeAsBytesSync(List.filled(3072, 1)),
    front: File('${tmp.path}/nv_gl_video_glFront_1.mp4')
      ..writeAsBytesSync(List.filled(2048, 2)),
  );

  test('les deux faces adoptées, et le journal les lit à leur NOUVELLE '
      'place', () async {
    final journal = <String>[];
    final faces = await terminerVideoOneshot(
      arreter: fausseCamera,
      adopter: keeper.adopt,
      journal: (m) async => journal.add(m),
    );
    expect(await faces.recto.length(), 3072, reason: 'arrière = recto');
    expect(await faces.verso.length(), 2048, reason: 'avant = verso');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(journal.single, contains('recto 3 Ko, verso 2 Ko'));
  });

  test('un journal qui échoue ne fait pas échouer la prise', () async {
    final faces = await terminerVideoOneshot(
      arreter: fausseCamera,
      adopter: keeper.adopt,
      journal: (_) async => throw StateError('journal en panne'),
    );
    expect(faces.recto.existsSync() && faces.verso.existsSync(), isTrue);
  });

  test('les deux faces ou aucune : une seconde adoption qui échoue fait '
      'échouer le tout', () async {
    var n = 0;
    await expectLater(
      terminerVideoOneshot(
        arreter: fausseCamera,
        adopter: (f) async {
          if (++n == 2) throw const FileSystemException('disque plein');
          return keeper.adopt(f);
        },
        journal: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
