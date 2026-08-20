import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Tests du ping 100 % local (chantier BLE 2026-07-13) : rotation des IDs
/// diffusés, anti-spam côté récepteur, TTL 12 h des messages.
void main() {
  const peer = PingPeerSnapshot(userId: 'peer', username: 'Alex');

  PingMessage msg(String id, bool mine, {Duration age = Duration.zero}) =>
      PingMessage(
        id: id,
        mine: mine,
        text: id,
        at: DateTime.now().subtract(age),
      );

  test('l\'ID diffusé change à chaque créneau de 15 min', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final slot = ProximityIdentity.slotIndex(DateTime.now());
    final now = await ProximityIdentity.pairToken(key, slot);
    final next = await ProximityIdentity.pairToken(key, slot + 1);
    final again = await ProximityIdentity.pairToken(key, slot);

    expect(now.length, 16);
    expect(now, isNot(equals(next)), reason: 'un tiers ne doit pas pister');
    expect(again, equals(now), reason: 'même créneau = même ID (amis)');
  });

  test('deux secrets de paire ne collident pas sur le même créneau', () async {
    final a = Uint8List.fromList(List.generate(32, (i) => i));
    final b = Uint8List.fromList(List.generate(32, (i) => 31 - i));
    final slot = ProximityIdentity.slotIndex(DateTime.now());
    expect(
      await ProximityIdentity.pairToken(a, slot),
      isNot(equals(await ProximityIdentity.pairToken(b, slot))),
    );
  });

  test('anti-spam : 3 messages entrants sans réponse maximum', () {
    var conv = PingConversation(
      peerId: 'peer',
      peer: peer,
      messages: [msg('1', false), msg('2', false), msg('3', false)],
    );
    expect(conv.unansweredIncoming, PingStore.unansweredLimit);

    // Je réponds : le compteur se libère (consigne Jay).
    conv = conv.copyWith(messages: [...conv.messages, msg('4', true)]);
    expect(conv.unansweredIncoming, 0);
    expect(conv.unansweredOutgoing, 1);
  });

  test('TTL 12 h : les messages plus vieux disparaissent', () {
    final conv = PingConversation(
      peerId: 'peer',
      peer: peer,
      messages: [
        msg('vieux', true, age: const Duration(hours: 13)),
        msg('recent', false, age: const Duration(hours: 2)),
      ],
    );
    final pruned = conv.pruned(PingStore.messageTtl);
    expect(pruned.messages.map((m) => m.id), ['recent']);
  });
}
