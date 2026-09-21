import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/drafts/draft_store.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/cards/editor/vibe_edit_draft.dart';
import 'package:neovibe/features/cards/send/share_plan.dart';
import 'package:neovibe/features/cards/send/share_plan_codec.dart';
import 'package:neovibe/features/cards/vibe_draft_keeper.dart';
import 'package:neovibe/features/connections/friendship.dart';
import 'package:neovibe/features/cards/editor/media_edit.dart';
import 'package:neovibe/features/cards/editor/media_edit_codec.dart';
import 'package:neovibe/features/cards/editor/color_grade.dart';
import 'package:neovibe/features/cards/editor/overlay_model.dart';

/// **Les brouillons** (2026-09-20) : ce qui est écrit se relit tel quel, et
/// ce qui a plus de trois jours part.
void main() {
  group('MediaEditCodec', () {
    test('une face éditée fait le va-et-vient sans rien perdre', () {
      final photo = MediaEdit(
        id: 'p1',
        source: File('/drafts/x/media_p1.jpg'),
        isVideo: false,
        srcWidth: 3000,
        srcHeight: 4000,
        rotation: 90,
        crop: const CropSpec(zoom: 1.7, cx: 0.3, cy: 0.6, angle: -12, turns: 1),
        filter: MediaFilter.clarendon,
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
      );
      final video = MediaEdit(
        id: 'v1',
        source: File('/drafts/x/media_v1.mp4'),
        isVideo: true,
        srcWidth: 1920,
        srcHeight: 1080,
        durationMs: 42000,
        trim: const VideoTrim(startMs: 3000, endMs: 33000, coverMs: 9000),
      );

      // Par le JSON TEXTE : c'est ce qui est sur le disque.
      MediaEdit back(MediaEdit m) => MediaEditCodec.mediaFromJson(
        jsonDecode(jsonEncode(MediaEditCodec.mediaToJson(m)))
            as Map<String, dynamic>,
      );

      final p = back(photo);
      expect(p, photo);
      expect(p.source.path, '/drafts/x/media_p1.jpg');
      expect(p.rotation, 90);
      expect(p.crop.zoom, 1.7);
      expect(p.crop.angle, -12);
      expect(p.crop.turns, 1);
      expect(p.filter, MediaFilter.clarendon);
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

      final v = back(video);
      expect(v, video);
      expect(v.isVideo, isTrue);
      expect(v.durationMs, 42000);
      expect(v.trim!.startMs, 3000);
      expect(v.trim!.endMs, 33000);
      expect(v.trim!.coverMs, 9000);
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
      kind: DraftKind.vibe,
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

    test('oublier retire le brouillon de la liste, pas ses fichiers', () async {
      final store = DraftStore(root: root);
      await store.save(brouillon('a', DateTime(2026, 9, 20)));
      final face = File('${(await store.dir('a')).path}/face.jpg');
      await face.writeAsString('…');
      await store.forget('a');
      expect(await store.list(), isEmpty);
      expect(face.existsSync(), isTrue, reason: 'l\'envoi la lit encore');
      // …et le balai emporte le dossier orphelin au prochain démarrage.
      await store.sweep();
      expect(face.existsSync(), isFalse);
    });

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

  group('SharePlanCodec', () {
    test('un plan complet fait le va-et-vient', () {
      const plan = SharePlan(
        story: StoryShare(
          tier: FriendshipTier.close,
          shareable: true,
          saveable: false,
        ),
        library: LibraryShare(isPublic: true, saveable: true, caption: 'Yo'),
        conversations: [
          ConversationShare(
            conversationId: 'c1',
            memberIds: ['u1', 'u2'],
            label: 'Les potes',
            saveable: true,
            dansLeChat: true,
            aussiDansLaBibliotheque: true,
          ),
          ConversationShare(
            peerId: 'u3',
            memberIds: ['u3'],
            label: 'Léa',
            dansLeChat: false,
            aussiDansLaBibliotheque: true,
          ),
        ],
        crossed: [CrossedShare(userId: 'u9', label: 'Croisé')],
        regles: ViewingRules(
          maxViews: 2,
          viewDurationSeconds: 7,
          scrubbable: true,
        ),
      );
      final back = SharePlanCodec.fromJson(
        jsonDecode(jsonEncode(SharePlanCodec.toJson(plan)))
            as Map<String, dynamic>,
      );
      expect(back.story!.tier, FriendshipTier.close);
      expect(back.story!.shareable, isTrue);
      expect(back.library!.isPublic, isTrue);
      expect(back.library!.caption, 'Yo');
      expect(back.conversations.length, 2);
      expect(back.conversations[0], plan.conversations[0]);
      expect(back.conversations[0].memberIds, ['u1', 'u2']);
      expect(back.conversations[0].label, 'Les potes');
      expect(back.conversations[1].key, 'peer:u3');
      expect(back.conversations[1].dansLeChat, isFalse);
      expect(back.crossed, [const CrossedShare(userId: 'u9', label: 'Croisé')]);
      expect(back.regles, plan.regles);
    });

    test('un plan vide reste vide', () {
      final back = SharePlanCodec.fromJson(
        SharePlanCodec.toJson(const SharePlan()),
      );
      expect(back.isEmpty, isTrue);
      expect(back.regles, const ViewingRules());
    });
  });

  group('VibeDraftState', () {
    test('la prise, les retouches et le plan se relisent tels quels', () {
      final state = VibeDraftState(
        type: CardType.oneshot,
        front: File('/drafts/v/a_front.mp4'),
        back: File('/drafts/v/b_back.mp4'),
        frontIsVideo: true,
        backIsVideo: true,
        frontImported: false,
        backImported: true,
        step: 'share',
        edit: VibeEditDraft(
          front: MediaEdit(
            id: 'f',
            source: File('/drafts/v/a_front.mp4'),
            isVideo: true,
            srcWidth: 1080,
            srcHeight: 1920,
            durationMs: 9000,
            filter: MediaFilter.clarendon,
          ),
        ),
        plan: const SharePlan(story: StoryShare()),
      );
      final back = VibeDraftState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      );
      expect(back.type, CardType.oneshot);
      expect(back.front!.path, '/drafts/v/a_front.mp4');
      expect(back.back!.path, '/drafts/v/b_back.mp4');
      expect(back.backImported, isTrue);
      expect(back.step, 'share');
      expect(back.edit!.front.filter, MediaFilter.clarendon);
      expect(back.edit!.back, isNull);
      expect(back.plan!.story, isNotNull);
      expect(back.summary, 'recto vidéo, verso vidéo');
    });
  });
}
