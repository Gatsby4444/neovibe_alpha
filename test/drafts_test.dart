import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/drafts/draft_store.dart';
import 'package:neovibe/core/models/library_item.dart';
import 'package:neovibe/features/library/album_editor/album_draft.dart';
import 'package:neovibe/features/library/album_editor/album_draft_codec.dart';
import 'package:neovibe/features/library/album_editor/color_grade.dart';
import 'package:neovibe/features/library/album_editor/overlay_model.dart';

/// **Les brouillons** (2026-09-20) : ce qui est écrit se relit tel quel, et
/// ce qui a plus de trois jours part.
void main() {
  group('AlbumDraftCodec', () {
    test('un brouillon complet fait le va-et-vient sans rien perdre', () {
      final draft = AlbumDraft(
        aspect: AlbumAspect.square,
        caption: 'Soirée au bord de l\'eau',
        captionFont: OverlayFont.moderne,
        isPublic: true,
        shareable: true,
        saveable: false,
        media: [
          AlbumDraftMedia(
            id: 'p1',
            source: File('/drafts/x/media_p1.jpg'),
            isVideo: false,
            srcWidth: 3000,
            srcHeight: 4000,
            rotation: 90,
            crop: const CropSpec(
              zoom: 1.7,
              cx: 0.3,
              cy: 0.6,
              angle: -12,
              turns: 1,
            ),
            filter: AlbumFilter.clarendon,
            filterStrength: 0.55,
            adjust: const ColorGrade(brightness: 0.1, warmth: -0.2, lux: 0.3),
            overlays: const [
              TextOverlay(
                id: 't1',
                text: 'Hello',
                font: OverlayFont.moderne,
                color: Color(0xFF12AB34),
                backdrop: TextBackdrop.translucent,
                alignment: TextAlignment.left,
                cx: 0.2,
                cy: 0.8,
                scale: 1.4,
                rotation: 0.3,
              ),
              StickerOverlay(id: 's1', emoji: '🔥', cx: 0.7, cy: 0.1),
              StickerOverlay(id: 's2', imagePath: '/drafts/x/sticker_s2.jpg'),
            ],
          ),
          AlbumDraftMedia(
            id: 'v1',
            source: File('/drafts/x/media_v1.mp4'),
            isVideo: true,
            srcWidth: 1920,
            srcHeight: 1080,
            durationMs: 42000,
            trim: const VideoTrim(startMs: 3000, endMs: 33000, coverMs: 9000),
          ),
        ],
      );

      // Par le JSON TEXTE : c'est ce qui est sur le disque.
      final back = AlbumDraftCodec.fromJson(
        jsonDecode(jsonEncode(AlbumDraftCodec.toJson(draft)))
            as Map<String, dynamic>,
      );

      expect(back.aspect, AlbumAspect.square);
      expect(back.caption, draft.caption);
      expect(back.captionFont, OverlayFont.moderne);
      expect(back.isPublic, isTrue);
      expect(back.shareable, isTrue);
      expect(back.saveable, isFalse);
      expect(back.media.length, 2);

      final p = back.media[0];
      expect(p.source.path, '/drafts/x/media_p1.jpg');
      expect(p.rotation, 90);
      expect(p.crop.zoom, 1.7);
      expect(p.crop.angle, -12);
      expect(p.crop.turns, 1);
      expect(p.filter, AlbumFilter.clarendon);
      expect(p.filterStrength, 0.55);
      expect(p.adjust.warmth, -0.2);
      expect(p.adjust.lux, 0.3);
      expect(p.overlays.length, 3);
      final t = p.overlays[0] as TextOverlay;
      expect(t.text, 'Hello');
      expect(t.color, const Color(0xFF12AB34));
      expect(t.backdrop, TextBackdrop.translucent);
      expect(t.alignment, TextAlignment.left);
      expect(t.scale, 1.4);
      expect(t.rotation, 0.3);
      expect((p.overlays[1] as StickerOverlay).emoji, '🔥');
      expect(
        (p.overlays[2] as StickerOverlay).imagePath,
        '/drafts/x/sticker_s2.jpg',
      );

      final v = back.media[1];
      expect(v.isVideo, isTrue);
      expect(v.durationMs, 42000);
      expect(v.trim!.startMs, 3000);
      expect(v.trim!.endMs, 33000);
      expect(v.trim!.coverMs, 9000);
    });

    test('un Flow reste un Flow', () {
      const draft = AlbumDraft(aspect: AlbumAspect.reel, flow: true);
      expect(
        AlbumDraftCodec.fromJson(AlbumDraftCodec.toJson(draft)).flow,
        true,
      );
    });
  });

  group('DraftStore', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('drafts');
    });
    tearDown(() => root.delete(recursive: true));

    Draft brouillon(String id, DateTime at) => Draft(
      id: id,
      kind: DraftKind.publication,
      step: 'edit',
      updatedAt: at,
      payload: const {'x': 1},
    );

    test('écrit, relu, listé du plus récent au plus vieux', () async {
      var changes = 0;
      final store = DraftStore(root: root, onChanged: () => changes++);
      final now = DateTime(2026, 9, 20, 12);
      await store.save(brouillon('a', now.subtract(const Duration(hours: 5))));
      await store.save(brouillon('b', now));
      expect(changes, 2);
      final list = await store.list();
      expect(list.map((d) => d.id), ['b', 'a']);
      expect((await store.load('a'))!.payload, {'x': 1});
      expect(File('${root.path}/a/draft.json.tmp').existsSync(), isFalse);
    });

    test(
      'le balai purge après trois jours, et les dossiers sans brouillon',
      () async {
        final store = DraftStore(root: root);
        final now = DateTime(2026, 9, 20, 12);
        await store.save(
          brouillon('vieux', now.subtract(const Duration(days: 3, minutes: 1))),
        );
        await store.save(
          brouillon('recent', now.subtract(const Duration(days: 2, hours: 23))),
        );
        await Directory('${root.path}/orphelin').create();
        await File('${root.path}/orphelin/media_x.mp4').writeAsString('…');

        expect(await store.sweep(now: now), 2);
        expect((await store.list()).map((d) => d.id), ['recent']);
        expect(Directory('${root.path}/vieux').existsSync(), isFalse);
        expect(Directory('${root.path}/orphelin').existsSync(), isFalse);
      },
    );

    test('supprimer emporte le dossier et ses fichiers', () async {
      final store = DraftStore(root: root);
      await store.save(brouillon('a', DateTime(2026, 9, 20)));
      await File(
        '${(await store.dir('a')).path}/media_1.jpg',
      ).writeAsString('…');
      await store.delete('a');
      expect(Directory('${root.path}/a').existsSync(), isFalse);
      expect(await store.list(), isEmpty);
    });
  });
}
