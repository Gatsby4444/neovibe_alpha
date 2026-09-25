import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/cards/send/share_plan.dart';
import 'package:neovibe/features/cards/send/vibe_draft.dart';

/// **Le Drop n'accepte que la caméra** (Jay, 2026-08-10, garde serveur le
/// 2026-09-25). Jusqu'au 2026-09-25, l'app ne retenait que « importée ou
/// non » : un fond uni passait pour une vraie photo, et la caméra principale
/// le laissait entrer dans un Drop. Ces tests tiennent les trois origines.
void main() {
  VibeDraft prise(FaceOrigin recto, {FaceOrigin? verso}) => VibeDraft(
    front: File('recto'),
    back: verso == null ? null : File('verso'),
    type: CardType.standard,
    frontOrigin: recto,
    backOrigin: verso ?? FaceOrigin.camera,
    frontIsVideo: false,
    backIsVideo: false,
  );

  group('origine des faces', () {
    test('caméra partout : entre au Drop', () {
      final d = prise(FaceOrigin.camera, verso: FaceOrigin.camera);
      expect(d.cameraOnly, isTrue);
      expect(d.imported, isFalse);
    });

    test('un fond uni n\'est PAS une import, mais n\'est pas la caméra', () {
      final d = prise(FaceOrigin.color);
      expect(d.imported, isFalse, reason: 'le badge « importée » mentirait');
      expect(d.cameraOnly, isFalse);
    });

    test('le verso compte aussi', () {
      expect(
        prise(FaceOrigin.camera, verso: FaceOrigin.color).cameraOnly,
        isFalse,
      );
      expect(
        prise(FaceOrigin.camera, verso: FaceOrigin.gallery).imported,
        isTrue,
      );
    });

    test('sans verso, son origine ne compte pas', () {
      final d = VibeDraft(
        front: File('recto'),
        back: null,
        type: CardType.standard,
        frontOrigin: FaceOrigin.camera,
        backOrigin: FaceOrigin.gallery,
        frontIsVideo: false,
        backIsVideo: false,
      );
      expect(d.cameraOnly, isTrue);
      expect(d.imported, isFalse);
    });

    test('le changement de type garde les origines', () {
      final d = prise(FaceOrigin.color).withType(CardType.oneOfOne);
      expect(d.frontOrigin, FaceOrigin.color);
      expect(d.cameraOnly, isFalse);
    });
  });

  group('écran d\'envoi', () {
    const drop = ConversationShare(
      conversationId: 'c',
      memberIds: ['1'],
      label: 'Soirée',
      dansLeChat: false,
      aussiDansLaBibliotheque: true,
    );
    const chat = ConversationShare(
      conversationId: 'c',
      memberIds: ['1'],
      label: 'Léa',
    );

    test('un fond uni vers un Drop est refusé, avec sa raison', () {
      final soucis = const SharePlan(
        conversations: [drop],
      ).problemes(CardType.standard, importe: false, cameraOnly: false);
      expect(soucis, hasLength(1));
      expect(soucis.single, contains('fonds unis'));
    });

    test('un fond uni vers un chat reste permis', () {
      expect(
        const SharePlan(
          conversations: [chat],
        ).problemes(CardType.standard, importe: false, cameraOnly: false),
        isEmpty,
      );
    });

    test('une import vers un Drop ne donne qu\'UNE raison', () {
      final soucis = const SharePlan(
        conversations: [drop],
      ).problemes(CardType.standard, importe: true, cameraOnly: false);
      expect(soucis, hasLength(1));
      expect(soucis.single, contains('galerie'));
    });
  });

  group('durée de lecture — une seule règle', () {
    CardModel vibe(CardType type, {bool frontVideo = false, bool? backVideo}) =>
        CardModel(
          id: 'x',
          ownerId: 'o',
          type: type,
          frontPath: 'f',
          backPath: backVideo == null ? null : 'b',
          frontIsVideo: frontVideo,
          backIsVideo: backVideo ?? false,
          createdAt: DateTime(2026),
        );

    test('Modifier une Vibe envoyée suit la règle de l\'envoi', () {
      expect(vibe(CardType.standard).acceptsDuration, isTrue);
      expect(vibe(CardType.oneshot, backVideo: false).acceptsDuration, isFalse);
      expect(
        vibe(CardType.standard, frontVideo: true).acceptsDuration,
        isFalse,
      );
      expect(
        vibe(
          CardType.standard,
          frontVideo: true,
          backVideo: false,
        ).acceptsDuration,
        isTrue,
      );
      expect(vibe(CardType.standard, frontVideo: true).hasVideo, isTrue);
    });
  });
}
