import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:neovibe/features/proximity/net/peer_network.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Identité en mémoire.
///
/// ⚠️ **La cryptographie est exactement celle de la production** — Ed25519, même
/// dérivation d'ID rotatif. On ne remplace que le **stockage** (le Keystore
/// Android, indisponible en test). Un double qui simulerait aussi l'algorithme
/// ne prouverait rien de ce qui tourne vraiment sur l'appareil.
///
/// ⚠️ **Un seul exemplaire pour toute la suite de tests.** Il en existait deux —
/// celui-ci et une copie dans `secure_channel_test.dart` — avec des graines
/// différentes et des méthodes qui ont divergé. Deux doubles d'un même objet
/// finissent toujours par tester deux choses différentes.
class IdentiteMemoire implements ProximityIdentity {
  IdentiteMemoire._(
    this.userId,
    this._pair,
    this._pub,
    this._x,
    this._xPub,
    this._pingSeed,
  );

  /// L'identifiant de compte de **cet appareil**.
  ///
  /// ⚠️ **Il ne décore pas le double, il est dans le protocole** : depuis le
  /// 2026-08-26 le jeton d'ami porte le nom de celui qui l'émet. Sans lui, le
  /// double ne saurait pas fabriquer une annonce que l'autre reconnaîtra.
  final String userId;

  static Future<IdentiteMemoire> creer({
    int graine = 1,
    String userId = 'u-double',
  }) async {
    final pair = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => (i * 7 + graine) % 256),
    );
    final pub = await pair.extractPublicKey();
    // ⚠️ **Une VRAIE paire X25519, pas un tableau d'octets quelconque.** Tout
    // l'intérêt du secret par paire est que les deux côtés obtiennent la même
    // valeur ; un double qui inventerait le partage ne prouverait rien.
    final x = await X25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => (i * 13 + graine * 5) % 256),
    );
    final xPub = await x.extractPublicKey();
    return IdentiteMemoire._(
      userId,
      pair,
      Uint8List.fromList(pub.bytes),
      x,
      Uint8List.fromList(xPub.bytes),
      Uint8List.fromList(List<int>.generate(32, (i) => (i * graine + 3) % 256)),
    );
  }

  final SimpleKeyPair _pair;
  final Uint8List _pub;
  final SimpleKeyPair _x;
  final Uint8List _xPub;
  Uint8List _pingSeed;

  final _secrets = <String, Uint8List>{};

  @override
  Future<Uint8List> edPublicKey() async => _pub;

  @override
  Future<Uint8List> x25519PublicKey() async => _xPub;

  @override
  Future<Uint8List> pairSecret(Uint8List friendX25519Pub) async {
    final cle = ProximityIdentity.hex(friendX25519Pub);
    final connu = _secrets[cle];
    if (connu != null) return connu;
    final partage = await X25519().sharedSecretKey(
      keyPair: _x,
      remotePublicKey: SimplePublicKey(
        friendX25519Pub,
        type: KeyPairType.x25519,
      ),
    );
    final derive = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: partage, info: utf8.encode('nv-pair-v3'));
    return _secrets[cle] = Uint8List.fromList(await derive.extractBytes());
  }

  @override
  Future<Map<String, Uint8List>> pairSecrets(
    Map<String, Uint8List> friendPublicKeys,
  ) async {
    final out = <String, Uint8List>{};
    for (final e in friendPublicKeys.entries) {
      out[e.key] = await pairSecret(e.value);
    }
    return out;
  }

  @override
  Uint8List pingSeed({bool renew = false}) {
    if (renew) {
      _pingSeed = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 29 + 7) % 256),
      );
    }
    return _pingSeed;
  }

  @override
  Future<void> forget() async {
    _secrets.clear();
  }

  @override
  Future<Uint8List> sign(List<int> message) async {
    final sig = await Ed25519().sign(message, keyPair: _pair);
    return Uint8List.fromList(sig.bytes);
  }

  @override
  Future<Uint8List> currentPublicPingId() => ProximityIdentity.publicPingId(
    _pingSeed,
    ProximityIdentity.slotIndex(DateTime.now()),
  );

  /// Le jeton que **cet appareil** émet à l'intention de [destinataire].
  ///
  /// ⚠️ **C'est le cœur du nouveau protocole, et ça ne se simule pas.** Le
  /// secret est réellement dérivé des deux vraies paires X25519 : si la
  /// dérivation ne donnait pas la même valeur des deux côtés, le test
  /// échouerait — ce qui est exactement ce qu'on veut qu'il prouve.
  Future<Uint8List> jetonPour(IdentiteMemoire destinataire, {int? slot}) async {
    final secret = await pairSecret(await destinataire.x25519PublicKey());
    return ProximityIdentity.pairToken(
      secret,
      slot ?? ProximityIdentity.slotIndex(DateTime.now()),
      // ⚠️ **C'est MOI qui émets.** Mettre ici l'identifiant du destinataire
      // ferait fabriquer au double exactement le jeton que le destinataire
      // s'apprête à crier — donc celui que son propre filtre anti-soi jette.
      // C'est la panne du 2026-08-26, reproduite dans les tests.
      emitter: userId,
    );
  }
}

/// Carnet d'amis en mémoire — même logique d'index rotatif que le vrai.
///
/// ⚠️ **Il prévient de ses changements, comme le vrai.** Sans ça, le test ne
/// pourrait pas voir le défaut du 2026-08-17 : des clés téléchargées après le
/// démarrage du réseau, et un index rotatif qui ne les voyait jamais.
class CarnetMemoire implements FriendKeyStore {
  final _amis = <String, FriendKeys>{};
  final _changes = _Notifier();

  @override
  Listenable get changes => _changes;

  @override
  Future<Map<String, FriendKeys>> all() async => _amis;

  @override
  Future<void> put(FriendKeys keys) async {
    _amis[keys.userId] = keys;
    _changes.ping();
  }

  @override
  Future<void> remove(String userId) async {
    if (_amis.remove(userId) != null) _changes.ping();
  }

  @override
  Future<void> replace(Iterable<FriendKeys> friends) async {
    _amis
      ..clear()
      ..addEntries(friends.map((f) => MapEntry(f.userId, f)));
    _changes.ping();
  }

  @override
  Future<void> clear() async {
    _amis.clear();
    _changes.ping();
  }
}

/// Une radio simulée, branchée sur une autre.
///
/// Ce qui sort d'un côté entre de l'autre, avec le même découpage en morceaux et
/// les mêmes événements de lien que le natif. C'est ce qui permet de faire
/// tourner **deux piles complètes** dans un test unitaire.
class RadioSimulee implements RadioCommands {
  RadioSimulee(this.adresse);

  final String adresse;
  RadioSimulee? pair;
  PeerNetwork? reseau;

  /// Simule un appareil qu'on ne peut pas joindre (hors de portée au moment de
  /// la connexion, pile GATT occupée, refus).
  var injoignable = false;

  /// Adresses vers lesquelles on a tenté d'ouvrir un lien.
  final connexions = <String>[];

  /// Adresses qu'on a demandé de couper.
  final coupures = <String>[];

  @override
  Future<int> connect(String address) async {
    connexions.add(address);
    final autre = pair;
    if (autre == null || autre.injoignable) {
      throw StateError('injoignable');
    }
    // ⚠️ **Le RÉCEPTEUR est prévenu en premier, et l'ordre n'est pas un
    // détail.** Sur la vraie pile, le périphérique voit l'abonnement à sa
    // caractéristique AVANT que le central ne reçoive la confirmation
    // d'écriture. Prévenir l'initiateur d'abord le faisait envoyer son `hello`
    // à un pair qui n'avait pas encore de canal.
    await autre.reseau?.onRadioEvent(
      RadioLink(linkId: adresse, connected: true, mtu: 185, incoming: true),
    );
    await reseau?.onRadioEvent(
      RadioLink(
        linkId: autre.adresse,
        connected: true,
        mtu: 185,
        incoming: false,
      ),
    );
    return 185;
  }

  @override
  void disconnect(String linkId) {
    coupures.add(linkId);
    final autre = pair;
    reseau?.onRadioEvent(
      RadioLink(linkId: linkId, connected: false, mtu: 0, incoming: false),
    );
    autre?.reseau?.onRadioEvent(
      RadioLink(linkId: adresse, connected: false, mtu: 0, incoming: true),
    );
  }

  @override
  Future<void> send(String linkId, Uint8List chunk) async {
    final autre = pair;
    if (autre == null || autre.injoignable) return;
    // Asynchrone comme la vraie pile : c'est ce délai qui révèle les défauts
    // d'ordre et d'entrelacement.
    await Future<void>.delayed(Duration.zero);
    await autre.reseau?.onRadioEvent(RadioFrame(adresse, chunk));
  }
}

/// Horloge pilotée, pour les échéances.
///
/// ⚠️ **Elle part de l'instant RÉEL, et ce n'est pas un détail.** L'ID rotatif
/// est dérivé du créneau de 15 minutes : `HMAC(clé, créneau)`. Si l'horloge du
/// réseau était figée à une date arbitraire pendant que l'identité qui émet
/// utilise l'horloge système, l'index couvrirait des créneaux sans rapport avec
/// les identifiants diffusés — et **aucun ami ne serait jamais reconnu**, pour
/// une raison qui n'a rien à voir avec le code testé.
///
/// Partir de maintenant garde les deux dans le même créneau ; les avances de
/// quelques secondes des tests n'en sortent pas.
class HorlogeMobile {
  DateTime instant = DateTime.now();
  DateTime call() => instant;
  void avance(Duration d) => instant = instant.add(d);
}

/// `notifyListeners` est protégée : seule une sous-classe peut l'appeler.
class _Notifier extends ChangeNotifier {
  void ping() => notifyListeners();
}
