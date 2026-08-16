import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/proximity_protocol.dart';
import 'package:neovibe/features/proximity/net/secure_channel.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Identité en mémoire : `ProximityIdentity` écrit dans le Keystore Android,
/// indisponible en test. On garde **exactement** la même cryptographie — c'est
/// le stockage qu'on remplace, pas l'algorithme, sans quoi le test ne prouverait
/// rien de ce qui tourne vraiment.
class IdentiteMemoire implements ProximityIdentity {
  IdentiteMemoire._(this._pair, this._pub, this._broadcast);

  static Future<IdentiteMemoire> creer({int graine = 1}) async {
    final pair = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => (i + graine) % 256),
    );
    final pub = await pair.extractPublicKey();
    return IdentiteMemoire._(
      pair,
      Uint8List.fromList(pub.bytes),
      Uint8List.fromList(List<int>.generate(32, (i) => (i * graine) % 256)),
    );
  }

  final SimpleKeyPair _pair;
  final Uint8List _pub;
  final Uint8List _broadcast;

  @override
  Future<Uint8List> edPublicKey() async => _pub;

  @override
  Future<Uint8List> broadcastKey() async => _broadcast;

  @override
  Future<Uint8List> sign(List<int> message) async {
    final sig = await Ed25519().sign(message, keyPair: _pair);
    return Uint8List.fromList(sig.bytes);
  }

  @override
  Future<Uint8List> currentRotatingId() =>
      ProximityIdentity.rotatingId(_broadcast, 0);
}

/// Fait la poignée de main complète entre deux canaux et rend le couple.
Future<(SecureChannel, SecureChannel)> apparier({
  ProximityIdentity? idA,
  ProximityIdentity? idB,
}) async {
  final a = SecureChannel(linkId: 'l', initiator: true, identity: idA);
  final b = SecureChannel(linkId: 'l', initiator: false, identity: idB);

  final hello = await a.hello() as HelloFrame;
  final refusB = await b.acceptHello(
    version: hello.version,
    peerEphemeral: hello.ephemeralPublicKey,
    peerDeviceKey: hello.devicePublicKey,
    signature: hello.signature,
  );
  expect(refusB, isNull);

  final ack = await b.hello() as HelloAckFrame;
  final refusA = await a.acceptHello(
    version: ack.version,
    peerEphemeral: ack.ephemeralPublicKey,
    peerDeviceKey: ack.devicePublicKey,
    signature: ack.signature,
  );
  expect(refusA, isNull);

  return (a, b);
}

ChatMessage motMessage(String texte) =>
    ChatMessage(id: 'm1', text: texte, sentAt: DateTime(2026, 8, 16, 12));

void main() {
  test('deux canaux appariés se comprennent dans les deux sens', () async {
    final (a, b) = await apparier(
      idA: await IdentiteMemoire.creer(graine: 1),
      idB: await IdentiteMemoire.creer(graine: 2),
    );
    expect(a.stage, ChannelStage.established);
    expect(b.stage, ChannelStage.established);

    final versB = await b.decrypt(await a.encrypt(motMessage('salut')));
    expect((versB! as ChatMessage).text, 'salut');

    final versA = await a.decrypt(await b.encrypt(motMessage('re')));
    expect((versA! as ChatMessage).text, 're');
  });

  test('une trame REJOUÉE est refusée', () async {
    final (a, b) = await apparier(
      idA: await IdentiteMemoire.creer(graine: 1),
      idB: await IdentiteMemoire.creer(graine: 2),
    );

    final frame = await a.encrypt(motMessage('je te dois 10 euros'));
    expect(await b.decrypt(frame), isNotNull);

    // Exactement la même trame, renvoyée. Sans compteur elle se déchiffrerait
    // parfaitement et le message réapparaîtrait — c'est le défaut de l'ancienne
    // couche, et sur un chat il suffit à faire dire deux fois la même chose.
    expect(await b.decrypt(frame), isNull);
  });

  test(
    'une signature de poignée de main invalide est REFUSÉE et nommée',
    () async {
      final a = SecureChannel(
        linkId: 'l',
        initiator: true,
        identity: await IdentiteMemoire.creer(graine: 1),
      );
      final imposteur = await IdentiteMemoire.creer(graine: 9);
      final hello = await a.hello() as HelloFrame;

      final b = SecureChannel(
        linkId: 'l',
        initiator: false,
        identity: await IdentiteMemoire.creer(graine: 2),
      );
      // La clé éphémère est relayée telle quelle, mais présentée avec la clé
      // d'appareil de l'imposteur : c'est exactement l'homme du milieu.
      final refus = await b.acceptHello(
        version: hello.version,
        peerEphemeral: hello.ephemeralPublicKey,
        peerDeviceKey: await imposteur.edPublicKey(),
        signature: hello.signature,
      );

      expect(refus, contains('signature'));
      expect(b.stage, ChannelStage.closed);
    },
  );

  test(
    'une version de protocole différente est refusée en le disant',
    () async {
      final b = SecureChannel(
        linkId: 'l',
        initiator: false,
        identity: await IdentiteMemoire.creer(graine: 2),
      );
      final refus = await b.acceptHello(
        version: protocolVersion + 1,
        peerEphemeral: Uint8List(32),
        peerDeviceKey: Uint8List(32),
        signature: Uint8List(64),
      );

      expect(refus, contains('incompatible'));
      expect(b.stage, ChannelStage.closed);
    },
  );

  test('un octet modifié fait échouer le déchiffrement', () async {
    final (a, b) = await apparier(
      idA: await IdentiteMemoire.creer(graine: 1),
      idB: await IdentiteMemoire.creer(graine: 2),
    );
    final frame = await a.encrypt(motMessage('intact'));
    final abime = EncryptedFrame(
      counter: frame.counter,
      cipherText: Uint8List.fromList(frame.cipherText)
        ..[0] = frame.cipherText[0] ^ 0xFF,
      mac: frame.mac,
    );

    expect(await b.decrypt(abime), isNull);
  });

  test('une trame forgée ne bloque pas la vraie trame suivante', () async {
    final (a, b) = await apparier(
      idA: await IdentiteMemoire.creer(graine: 1),
      idB: await IdentiteMemoire.creer(graine: 2),
    );

    // Un attaquant envoie une trame illisible avec un compteur très en avance.
    final forgee = EncryptedFrame(
      counter: 5000,
      cipherText: Uint8List.fromList([1, 2, 3]),
      mac: Uint8List(16),
    );
    expect(await b.decrypt(forgee), isNull);

    // Si le compteur avait avancé AVANT la vérification, la vraie trame
    // suivante aurait été rejetée comme un rejeu — un déni de service à une
    // seule trame.
    final vraie = await a.encrypt(motMessage('toujours là'));
    expect(await b.decrypt(vraie), isNotNull);
  });

  test(
    'la clé d\'appareil du profil doit être celle de la poignée de main',
    () async {
      final idA = await IdentiteMemoire.creer(graine: 1);
      final (_, b) = await apparier(
        idA: idA,
        idB: await IdentiteMemoire.creer(graine: 2),
      );

      expect(b.isPeerDeviceKey(await idA.edPublicKey()), isTrue);
      final autre = await IdentiteMemoire.creer(graine: 9);
      expect(b.isPeerDeviceKey(await autre.edPublicKey()), isFalse);
    },
  );

  test('les trames se décodent en aller-retour, sans perte', () {
    final messages = <PeerMessage>[
      motMessage('coucou'),
      ProfileMessage(
        userId: 'u1',
        username: 'Mimi',
        tagName: 'mimi',
        devicePublicKey: Uint8List.fromList([1, 2, 3]),
        signature: Uint8List.fromList([4, 5, 6]),
      ),
      CertOfferMessage(
        a: 'u1',
        b: 'u2',
        timestamp: '2026-08-16T12:00:00Z',
        signatureA: Uint8List.fromList([7]),
        devicePublicKeyA: Uint8List.fromList([8]),
      ),
      const CertFinalMessage({'a': 'u1', 'b': 'u2', 'ts': 'x'}),
      FriendRequestMessage(
        from: 'u1',
        to: 'u2',
        timestamp: 'ts',
        signature: Uint8List.fromList([1]),
        devicePublicKey: Uint8List.fromList([2]),
        broadcastKey: Uint8List.fromList([3]),
      ),
      FriendAcceptMessage(
        record: const {'from': 'u1', 'to': 'u2', 'ts': 'x', 'sigFrom': 'y'},
        devicePublicKey: Uint8List.fromList([4]),
        broadcastKey: Uint8List.fromList([5]),
      ),
      const FriendDeclineMessage(),
    ];

    for (final message in messages) {
      final relu = PeerMessage.decode(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      expect(
        relu.runtimeType,
        message.runtimeType,
        reason: '${message.toJson()}',
      );
    }
  });

  test('une trame illisible rend null au lieu de lever', () {
    expect(WireFrame.decode(Uint8List.fromList([0, 1, 2])), isNull);
    expect(WireFrame.decode(Uint8List.fromList(utf8.encode('{}'))), isNull);
  });
}
