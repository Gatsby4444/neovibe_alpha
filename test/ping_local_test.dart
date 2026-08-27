import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Ce que le ping calcule tout seul : la **rotation** de l'identifiant diffusé,
/// et le fait que deux paires n'entrent jamais en collision.
void main() {
  test('l\'ID diffusé change à chaque créneau de 15 min', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final slot = ProximityIdentity.slotIndex(DateTime.now());
    // L'émetteur est fixe : ce qu'on mesure ici, c'est l'effet du CRÉNEAU.
    final now = await ProximityIdentity.pairToken(key, slot, emitter: 'u-a');
    final next = await ProximityIdentity.pairToken(
      key,
      slot + 1,
      emitter: 'u-a',
    );
    final again = await ProximityIdentity.pairToken(key, slot, emitter: 'u-a');

    expect(now.length, 16);
    expect(now, isNot(equals(next)), reason: 'un tiers ne doit pas pister');
    expect(again, equals(now), reason: 'même créneau = même ID (amis)');
  });

  test('deux secrets de paire ne collident pas sur le même créneau', () async {
    final a = Uint8List.fromList(List.generate(32, (i) => i));
    final b = Uint8List.fromList(List.generate(32, (i) => 31 - i));
    final slot = ProximityIdentity.slotIndex(DateTime.now());
    expect(
      await ProximityIdentity.pairToken(a, slot, emitter: 'u-a'),
      isNot(equals(await ProximityIdentity.pairToken(b, slot, emitter: 'u-a'))),
    );
  });

  // ⚠️ **« anti-spam : 3 messages entrants » et « TTL 12 h » ont été retirés le
  // 2026-08-27**, avec les conversations ping locales qu'ils protégeaient. La
  // messagerie de proximité passe par le serveur, qui a ses propres règles :
  // garder ici une seconde limite, muette et invisible, faisait deux arbitres
  // pour une même conversation.
}
