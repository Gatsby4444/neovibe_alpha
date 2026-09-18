import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/cards/editor/vibe_edit_draft.dart';
import 'package:neovibe/features/library/album_editor/album_draft.dart';
import 'package:neovibe/features/library/album_editor/color_grade.dart';
import 'package:neovibe/features/library/album_editor/overlay_model.dart';

/// Le brouillon d'une Vibe : ce qu'« Original » rend, et ce que l'export a
/// le droit de ne PAS retranscoder.
void main() {
  AlbumDraftMedia face(String id, {bool video = false}) => AlbumDraftMedia(
    id: id,
    source: File('$id.jpg'),
    isVideo: video,
    srcWidth: 900,
    srcHeight: 1600,
    durationMs: video ? 12000 : null,
  );

  test('une face telle que capturée est vierge', () {
    final d = VibeEditDraft(front: face('r'), back: face('v', video: true));
    expect(d.frontEdited, isFalse);
    expect(d.backEdited, isFalse);
  });

  test('chaque réglage rend la face retouchée', () {
    final d = VibeEditDraft(front: face('r'));
    expect(
      d
          .update(true, (m) => m.copyWith(crop: const CropSpec(zoom: 1.2)))
          .frontEdited,
      isTrue,
    );
    expect(
      d
          .update(true, (m) => m.copyWith(filter: AlbumFilter.values[1]))
          .frontEdited,
      isTrue,
    );
    expect(
      d
          .update(
            true,
            (m) => m.copyWith(adjust: const ColorGrade(brightness: 0.2)),
          )
          .frontEdited,
      isTrue,
    );
    expect(
      d
          .update(true, (m) => m.withOverlay(TextOverlay(id: 't', text: 'yo')))
          .frontEdited,
      isTrue,
    );
    expect(
      d.update(true, (m) => m.copyWith(filterStrength: 0.5)).frontEdited,
      isTrue,
    );
  });

  test('« Original » efface les réglages d\'UNE face, pas de l\'autre', () {
    var d = VibeEditDraft(front: face('r'), back: face('v'));
    d = d.update(true, (m) => m.copyWith(crop: const CropSpec(zoom: 2)));
    d = d.update(false, (m) => m.withOverlay(TextOverlay(id: 't', text: 'x')));
    expect(d.frontEdited && d.backEdited, isTrue);
    final r = d.restore(isFront: true);
    expect(r.frontEdited, isFalse);
    expect(r.backEdited, isTrue, reason: 'le verso garde son texte');
    expect(r.front.id, 'r', reason: 'la face garde son identité');
  });

  test('sans verso, la face courante est toujours le recto', () {
    final d = VibeEditDraft(front: face('r'));
    expect(d.hasBack, isFalse);
    expect(d.face(front: true).id, 'r');
  });
}
