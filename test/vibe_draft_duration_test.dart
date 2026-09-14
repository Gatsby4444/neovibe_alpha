import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/cards/send/vibe_draft.dart';

/// Ce que ce test défend : **la durée de lecture n'a de sens que pour les faces
/// photo d'une Vibe standard.** Un Oneshot n'a jamais de chrono (Jay,
/// 2026-09-14), une face vidéo se lit en entier (2026-07-12). La roue ⚙︎ et
/// l'envoi lisent la même réponse (`acceptsDuration`) : c'est ce qui empêche
/// un curseur qui ne règle rien, ou une durée envoyée sans curseur.
void main() {
  VibeDraft draft(CardType type, {bool frontVideo = false, bool? backVideo}) =>
      VibeDraft(
        front: File('recto'),
        back: backVideo == null ? null : File('verso'),
        type: type,
        imported: false,
        frontIsVideo: frontVideo,
        backIsVideo: backVideo ?? false,
      );

  test('une standard photo accepte une durée', () {
    expect(draft(CardType.standard).acceptsDuration, isTrue);
    expect(draft(CardType.standard, backVideo: false).acceptsDuration, isTrue);
  });

  test('une standard vidéo + photo accepte une durée (pour la face photo)', () {
    expect(
      draft(
        CardType.standard,
        frontVideo: true,
        backVideo: false,
      ).acceptsDuration,
      isTrue,
    );
  });

  test('une standard tout vidéo n\'en accepte pas', () {
    expect(
      draft(
        CardType.standard,
        frontVideo: true,
        backVideo: true,
      ).acceptsDuration,
      isFalse,
    );
    expect(draft(CardType.standard, frontVideo: true).acceptsDuration, isFalse);
  });

  test('un Oneshot n\'en accepte JAMAIS, même en photo', () {
    // 🔴 Le contre-test de la règle du 2026-09-14 : retirer `type !=
    // oneshot` de `acceptsDuration` fait tomber cette ligne, et elle seule.
    expect(draft(CardType.oneshot, backVideo: false).acceptsDuration, isFalse);
    expect(
      draft(
        CardType.oneshot,
        frontVideo: true,
        backVideo: true,
      ).acceptsDuration,
      isFalse,
    );
  });
}
