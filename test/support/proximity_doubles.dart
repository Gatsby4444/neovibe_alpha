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
  Uint8List _broadcast;
  Uint8List? _precedente;
  DateTime _tournee = DateTime(2026, 8, 18);

  /// Combien de fois la clé de diffusion a tourné. Le test s'en sert pour
  /// vérifier qu'une révocation a bien lieu — et une seule fois.
  var rotations = 0;

  @override
  Future<Uint8List> edPublicKey() async => _pub;

  @override
  Future<Uint8List> broadcastKey() async => _broadcast;

  @override
  Future<Uint8List?> previousBroadcastKey() async => _precedente;

  @override
  Future<DateTime> broadcastRotatedAt() async => _tournee;

  @override
  Future<bool> rotateBroadcastIfDue() async {
    if (DateTime.now().difference(_tournee) <
        ProximityIdentity.rotationPeriod) {
      return false;
    }
    await rotateBroadcast(keepPrevious: true);
    return true;
  }

  @override
  Future<void> rotateBroadcast({required bool keepPrevious}) async {
    _precedente = keepPrevious ? _broadcast : null;
    rotations++;
    _broadcast = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 11 + rotations * 17) % 256),
    );
    _tournee = DateTime.now();
  }

  @override
  Future<void> forget() async {
    _precedente = null;
    _broadcast = Uint8List(32);
  }

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

  /// Indexe **les deux clés** de chaque ami — courante et précédente — comme le
  /// vrai carnet. C'est ce qui permet à un ami qui vient de faire tourner sa
  /// clé de rester reconnu.
  @override
  Future<Map<String, FriendKeys>> rotatingIndex(int slot) async {
    final index = <String, FriendKeys>{};
    for (final ami in _amis.values) {
      for (final cle in ami.broadcastKeys) {
        for (final s in [slot - 1, slot, slot + 1]) {
          final id = await ProximityIdentity.rotatingId(cle, s);
          index[FriendKeyBook.hex(id)] = ami;
        }
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
