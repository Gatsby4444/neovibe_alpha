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
  final a = SecureChannel(linkId: 'l', identity: idA);
  final b = SecureChannel(linkId: 'l', identity: idB);
  await echanger(a, b);
  return (a, b);
}

/// Une poignée de main complète : [ouvrant] ouvre, [repondant] répond.
///
/// Sert aussi à REJOUER une poignée de main sur des canaux déjà appariés —
/// c'est ce que fait un pair qui a perdu sa session.
Future<void> echanger(SecureChannel ouvrant, SecureChannel repondant) async {
  final hello = await ouvrant.open() as HelloFrame;
  final refusB = await repondant.acceptHello(
    version: hello.version,
    peerEphemeral: hello.ephemeralPublicKey,
    peerDeviceKey: hello.devicePublicKey,
    signature: hello.signature,
    weWillAnswer: true,
  );
  expect(refusB, isNull);

  final ack = await repondant.answer() as HelloAckFrame;
  final refusA = await ouvrant.acceptHello(
    version: ack.version,
    peerEphemeral: ack.ephemeralPublicKey,
    peerDeviceKey: ack.devicePublicKey,
    signature: ack.signature,
    weWillAnswer: false,
  );
  expect(refusA, isNull);
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
        identity: await IdentiteMemoire.creer(graine: 1),
      );
      final imposteur = await IdentiteMemoire.creer(graine: 9);
      final hello = await a.open() as HelloFrame;

      final b = SecureChannel(
        linkId: 'l',
        identity: await IdentiteMemoire.creer(graine: 2),
      );
      // La clé éphémère est relayée telle quelle, mais présentée avec la clé
      // d'appareil de l'imposteur : c'est exactement l'homme du milieu.
      final refus = await b.acceptHello(
        version: hello.version,
        peerEphemeral: hello.ephemeralPublicKey,
        peerDeviceKey: await imposteur.edPublicKey(),
        signature: hello.signature,
        weWillAnswer: true,
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
        identity: await IdentiteMemoire.creer(graine: 2),
      );
      final refus = await b.acceptHello(
        version: protocolVersion + 1,
        peerEphemeral: Uint8List(32),
        peerDeviceKey: Uint8List(32),
        signature: Uint8List(64),
        weWillAnswer: true,
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

  testsAcceptationAmi();

  test('une trame illisible rend null au lieu de lever', () {
    expect(WireFrame.decode(Uint8List.fromList([0, 1, 2])), isNull);
    expect(WireFrame.decode(Uint8List.fromList(utf8.encode('{}'))), isNull);
  });

  // ------------------------------------------------------------------
  // Reconstruction de session — la quatrième cause de message fantôme
  // ------------------------------------------------------------------

  test(
    'un pair qui reconstruit sa session est SUIVI, compteurs compris',
    () async {
      final idA = await IdentiteMemoire.creer(graine: 1);
      final idB = await IdentiteMemoire.creer(graine: 2);
      final (a, b) = await apparier(idA: idA, idB: idB);

      // Un échange normal : c'est lui qui fait avancer les compteurs, et donc ce
      // qui rendait la session neuve d'en face inacceptable.
      expect(await a.decrypt(await b.encrypt(motMessage('un'))), isNotNull);
      expect(await a.decrypt(await b.encrypt(motMessage('deux'))), isNotNull);

      // B perd tout et repart d'un canal neuf — compteur d'envoi à 0.
      final bNeuf = SecureChannel(linkId: 'l', identity: idB);
      await echanger(bNeuf, a);

      // ⚠️ Sans le correctif, A refusait ici : « déchiffrement refusé, compteur
      // 0 », exactement ce que le journal des appareils de Jay a montré le
      // 2026-08-17. La clé était bonne ; c'est le compteur qui bloquait.
      final recu = await a.decrypt(
        await bNeuf.encrypt(motMessage('tu me lis ?')),
      );
      expect((recu! as ChatMessage).text, 'tu me lis ?');

      // Et dans l'autre sens aussi : reconstruire, c'est tout ou rien.
      final retour = await bNeuf.decrypt(await a.encrypt(motMessage('oui')));
      expect((retour! as ChatMessage).text, 'oui');

      expect(a.rekeys, 1);
    },
  );

  test('un hello RÉPÉTÉ ne remet pas les compteurs à zéro', () async {
    // ⚠️ Le revers du test précédent, et il compte autant. Si n'importe quel
    // `hello` remettait les compteurs à zéro, il suffirait d'en rejouer un pour
    // rouvrir la porte au rejeu de trames — la faille même que le compteur
    // existe pour fermer.
    final idA = await IdentiteMemoire.creer(graine: 1);
    final idB = await IdentiteMemoire.creer(graine: 2);
    final a = SecureChannel(linkId: 'l', identity: idA);
    final b = SecureChannel(linkId: 'l', identity: idB);

    final hello = await a.open() as HelloFrame;
    await b.acceptHello(
      version: hello.version,
      peerEphemeral: hello.ephemeralPublicKey,
      peerDeviceKey: hello.devicePublicKey,
      signature: hello.signature,
      weWillAnswer: true,
    );
    final ack = await b.answer() as HelloAckFrame;
    await a.acceptHello(
      version: ack.version,
      peerEphemeral: ack.ephemeralPublicKey,
      peerDeviceKey: ack.devicePublicKey,
      signature: ack.signature,
      weWillAnswer: false,
    );

    final frame = await a.encrypt(motMessage('je te dois 10 euros'));
    expect(await b.decrypt(frame), isNotNull);

    // Le MÊME hello, rejoué. La clé éphémère n'a pas changé : ce n'est pas une
    // nouvelle session, donc rien ne bouge.
    final refus = await b.acceptHello(
      version: hello.version,
      peerEphemeral: hello.ephemeralPublicKey,
      peerDeviceKey: hello.devicePublicKey,
      signature: hello.signature,
      weWillAnswer: true,
    );
    expect(refus, isNull);
    expect(b.rekeys, 0);

    // Et la trame rejouée reste refusée.
    expect(await b.decrypt(frame), isNull);
  });

  test('on refuse qu\'on nous renvoie notre PROPRE clé éphémère', () async {
    // La réflexion était écartée par le rôle signé (`i` / `r`). Le rôle a été
    // retiré — il dépendait de qui avait appelé, ce dont les deux côtés ne
    // conviennent pas toujours — et la protection est devenue explicite.
    final id = await IdentiteMemoire.creer(graine: 1);
    final a = SecureChannel(linkId: 'l', identity: id);
    final hello = await a.open() as HelloFrame;

    final refus = await a.acceptHello(
      version: hello.version,
      peerEphemeral: hello.ephemeralPublicKey,
      peerDeviceKey: hello.devicePublicKey,
      signature: hello.signature,
      weWillAnswer: true,
    );
    expect(refus, contains('réfléchie'));
  });

  test('deux ouvertures qui se CROISENT donnent une seule session', () async {
    // ⚠️ L'invariant qui remplace les rôles. Les deux côtés ouvrent désormais
    // la poignée de main — plus personne n'attend que l'autre parle. Il faut
    // donc que deux ouvertures simultanées aboutissent au même endroit.
    final idA = await IdentiteMemoire.creer(graine: 1);
    final idB = await IdentiteMemoire.creer(graine: 2);
    final a = SecureChannel(linkId: 'l', identity: idA);
    final b = SecureChannel(linkId: 'l', identity: idB);

    final helloA = await a.open() as HelloFrame;
    final helloB = await b.open() as HelloFrame;

    // Chacun reçoit l'ouverture de l'autre et y répond.
    expect(
      await b.acceptHello(
        version: helloA.version,
        peerEphemeral: helloA.ephemeralPublicKey,
        peerDeviceKey: helloA.devicePublicKey,
        signature: helloA.signature,
        weWillAnswer: true,
      ),
      isNull,
    );
    expect(
      await a.acceptHello(
        version: helloB.version,
        peerEphemeral: helloB.ephemeralPublicKey,
        peerDeviceKey: helloB.devicePublicKey,
        signature: helloB.signature,
        weWillAnswer: true,
      ),
      isNull,
    );

    // Puis chacun reçoit la réponse de l'autre : elle ne doit RIEN changer.
    final serialA = a.sessionSerial;
    final ackB = await b.answer() as HelloAckFrame;
    expect(
      await a.acceptHello(
        version: ackB.version,
        peerEphemeral: ackB.ephemeralPublicKey,
        peerDeviceKey: ackB.devicePublicKey,
        signature: ackB.signature,
        weWillAnswer: false,
      ),
      isNull,
    );
    expect(a.sessionSerial, serialA, reason: 'même session, rien à refaire');

    // Et les deux se comprennent, dans les deux sens — donc les préfixes de
    // nonce sont opposés, alors qu'aucun des deux n'a « composé le numéro ».
    expect(
      ((await b.decrypt(await a.encrypt(motMessage('a→b'))))! as ChatMessage)
          .text,
      'a→b',
    );
    expect(
      ((await a.decrypt(await b.encrypt(motMessage('b→a'))))! as ChatMessage)
          .text,
      'b→a',
    );
  });
}

/// ⚠️ **Une acceptation d'ami ne se croit pas sur parole (2026-08-17).**
///
/// `_onFriendAccept` ne vérifiait **rien** : elle rangeait l'émetteur dans le
/// carnet d'amis sur la seule foi du message. N'importe quel pair ayant abouti
/// la poignée de main — donc n'importe qui de physiquement à côté — pouvait
/// s'inscrire lui-même comme ami : affiché comme tel, exempté de la règle
/// anti-spam, et reconnu en silence à son identifiant rotatif ensuite.
///
/// Pour une app dont toute la thèse est qu'**être à côté ne suffit pas à être
/// ami**, c'était la barrière fondatrice qui tombait, localement et sans bruit.
void testsAcceptationAmi() {
  Future<FriendAcceptMessage> acceptation({
    required ProximityIdentity demandeur,
    required ProximityIdentity accepteur,
    required String de,
    required String vers,
  }) async {
    const ts = '2026-08-17T18:00:00.000Z';
    final demande = FriendRequestMessage(
      from: de,
      to: vers,
      timestamp: ts,
      signature: await demandeur.sign(
        FriendRequestMessage.signedPayload(de, vers, ts),
      ),
      devicePublicKey: await demandeur.edPublicKey(),
      broadcastKey: await demandeur.broadcastKey(),
    );
    return FriendAcceptMessage(
      record: {
        ...demande.record,
        'sigTo': base64Encode(
          await accepteur.sign(FriendAcceptMessage.signedPayload(de, vers, ts)),
        ),
      },
      devicePublicKey: await accepteur.edPublicKey(),
      broadcastKey: await accepteur.broadcastKey(),
    );
  }

  test('une acceptation LÉGITIME passe', () async {
    final moi = await IdentiteMemoire.creer(graine: 1);
    final lui = await IdentiteMemoire.creer(graine: 2);
    final accept = await acceptation(
      demandeur: moi,
      accepteur: lui,
      de: 'u-moi',
      vers: 'u-lui',
    );

    expect(
      await accept.refusalFor(
        me: 'u-moi',
        peerUserId: 'u-lui',
        myDeviceKey: await moi.edPublicKey(),
      ),
      isNull,
    );
  });

  test('une acceptation JAMAIS DEMANDÉE est refusée', () async {
    // L'attaquant fabrique une demande entière — la nôtre, prétend-il — et
    // l'accepte lui-même. Tout est bien signé… mais pas par nous.
    final moi = await IdentiteMemoire.creer(graine: 1);
    final attaquant = await IdentiteMemoire.creer(graine: 42);
    final forge = await acceptation(
      demandeur: attaquant, // ← il signe à notre place
      accepteur: attaquant,
      de: 'u-moi',
      vers: 'u-attaquant',
    );

    expect(
      await forge.refusalFor(
        me: 'u-moi',
        peerUserId: 'u-attaquant',
        myDeviceKey: await moi.edPublicKey(),
      ),
      contains('jamais émise'),
      reason: 'un tiers ne peut pas fabriquer NOTRE signature',
    );
  });

  test('une acceptation destinée à QUELQU\'UN D\'AUTRE est refusée', () async {
    // Interceptée sur le fil, puis rejouée vers nous par un troisième.
    final moi = await IdentiteMemoire.creer(graine: 1);
    final autre = await IdentiteMemoire.creer(graine: 3);
    final accept = await acceptation(
      demandeur: moi,
      accepteur: autre,
      de: 'u-moi',
      vers: 'u-autre',
    );

    expect(
      await accept.refusalFor(
        me: 'u-moi',
        peerUserId: 'u-intrus',
        myDeviceKey: await moi.edPublicKey(),
      ),
      contains('quelqu\'un d\'autre'),
    );
  });
}
