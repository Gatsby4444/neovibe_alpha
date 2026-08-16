import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:neovibe/features/proximity/net/peer_network.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Identité en mémoire.
///
/// ⚠️ **La cryptographie est exactement celle de la production** — Ed25519, même
/// dérivation d'ID rotatif. On ne remplace que le **stockage** (le Keystore
/// Android, indisponible en test). Un double qui simulerait aussi l'algorithme
/// ne prouverait rien de ce qui tourne vraiment sur l'appareil.
class IdentiteMemoire implements ProximityIdentity {
  IdentiteMemoire._(this._pair, this._pub, this._broadcast);

  static Future<IdentiteMemoire> creer({int graine = 1}) async {
    final pair = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => (i * 7 + graine) % 256),
    );
    final pub = await pair.extractPublicKey();
    return IdentiteMemoire._(
      pair,
      Uint8List.fromList(pub.bytes),
      Uint8List.fromList(List<int>.generate(32, (i) => (i * graine + 3) % 256)),
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
  Future<Uint8List> currentRotatingId() => ProximityIdentity.rotatingId(
    _broadcast,
    ProximityIdentity.slotIndex(DateTime.now()),
  );
}

/// Carnet d'amis en mémoire — même logique d'index rotatif que le vrai.
class CarnetMemoire implements FriendKeyStore {
  final _amis = <String, FriendKeys>{};

  @override
  Future<Map<String, FriendKeys>> all() async => _amis;

  @override
  Future<void> put(FriendKeys keys) async => _amis[keys.userId] = keys;

  @override
  Future<void> remove(String userId) async => _amis.remove(userId);

  @override
  Future<void> clear() async => _amis.clear();

  @override
  Future<Map<String, FriendKeys>> rotatingIndex(int slot) async {
    final index = <String, FriendKeys>{};
    for (final ami in _amis.values) {
      for (final s in [slot - 1, slot, slot + 1]) {
        final id = await ProximityIdentity.rotatingId(ami.broadcastKey, s);
        index[id.map((b) => b.toRadixString(16).padLeft(2, '0')).join()] = ami;
      }
    }
    return index;
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

  @override
  Future<int> connect(String address) async {
    connexions.add(address);
    final autre = pair;
    if (autre == null || autre.injoignable) {
      throw StateError('injoignable');
    }
    // ⚠️ **Le RÉCEPTEUR est prévenu en premier, et l'ordre n'est pas un
    // détail.** Sur la vraie pile, le périphérique voit l'abonnement à sa
    // caractéristique (`onDescriptorWriteRequest`) AVANT que le central ne
    // reçoive la confirmation d'écriture (`onDescriptorWrite`). Prévenir
    // l'initiateur d'abord le faisait envoyer son `hello` à un pair qui n'avait
    // pas encore de canal : la trame tombait dans le vide, et la poignée de
    // main n'aboutissait jamais.
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
class HorlogeMobile {
  DateTime instant = DateTime(2026, 8, 16, 12);
  DateTime call() => instant;
  void avance(Duration d) => instant = instant.add(d);
}
