import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:neovibe/features/proximity/net/ble_radio.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Identité en mémoire.
///
/// ⚠️ **La cryptographie est exactement celle de la production** — X25519, même
/// dérivation d'ID rotatif. On ne remplace que le **stockage** (le Keystore
/// Android, indisponible en test). Un double qui simulerait aussi l'algorithme
/// ne prouverait rien de ce qui tourne vraiment sur l'appareil.
///
/// ⚠️ **Le tampon Ed25519 a été retiré le 2026-08-27**, ici comme en production.
/// Un double qui garderait une capacité que l'objet réel n'a plus laisserait
/// passer des tests qui ne prouvent plus rien.
///
/// ⚠️ **Un seul exemplaire pour toute la suite de tests.** Il en existait deux —
/// celui-ci et une copie dans `secure_channel_test.dart` — avec des graines
/// différentes et des méthodes qui ont divergé. Deux doubles d'un même objet
/// finissent toujours par tester deux choses différentes.
class IdentiteMemoire implements ProximityIdentity {
  IdentiteMemoire._(this.userId, this._x, this._xPub, this._pingSeed);

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
    // ⚠️ **Une VRAIE paire X25519, pas un tableau d'octets quelconque.** Tout
    // l'intérêt du secret par paire est que les deux côtés obtiennent la même
    // valeur ; un double qui inventerait le partage ne prouverait rien.
    final x = await X25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => (i * 13 + graine * 5) % 256),
    );
    final xPub = await x.extractPublicKey();
    return IdentiteMemoire._(
      userId,
      x,
      Uint8List.fromList(xPub.bytes),
      Uint8List.fromList(List<int>.generate(32, (i) => (i * graine + 3) % 256)),
    );
  }

  final SimpleKeyPair _x;
  final Uint8List _xPub;
  Uint8List _pingSeed;

  final _secrets = <String, Uint8List>{};

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

  // ⚠️ **Ce ne sont plus des `@override` depuis le 2026-08-28** : `put` et
  // `remove` ont été retirés de `FriendKeyStore`, qui ne sait plus que
  // **remplacer** — la seule façon correcte de tenir un carnet dont le serveur
  // est la source. Ces deux-là restent ici comme **outils de montage de test**,
  // pour préparer un carnet ligne à ligne sans passer par un `replace`.
  Future<void> put(FriendKeys keys) async {
    _amis[keys.userId] = keys;
    _changes.ping();
  }

  Future<void> retire(String userId) async {
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

// ⚠️ **`RadioSimulee` a été SUPPRIMÉE le 2026-08-27**, avec l'interface
// `RadioCommands` qu'elle implémentait et tout le transport BLE.
//
// Elle branchait deux piles complètes l'une sur l'autre : ce qui sortait d'un
// côté entrait de l'autre, avec le même découpage en morceaux et les mêmes
// événements de lien que le natif. C'était le montage qui avait remplacé « deux
// téléphones dans les mains de Jay » par quelques millisecondes de test.
//
// Le réseau de pairs ne donne plus **aucun** ordre à la radio : il ne fait
// qu'écouter ce qu'elle constate. Il n'y a donc plus de commandes à simuler,
// et un `RadioScan` suffit à tout ce qui reste à éprouver.

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

/// **LA** radio factice de toute la suite de tests.
///
/// ⚠️ **Un seul exemplaire, comme l'identite et le carnet.** Elle vivait
/// dans `proximity_supervisor_test.dart` ; le test du balayage des amis en
/// avait besoin a son tour, et deux doubles d'un meme objet finissent toujours
/// par tester deux choses differentes.
///
/// Tout ce qu'elle fait, c'est **compter**. C'est deliberement son seul talent :
/// les defauts que ce projet traque ne levent rien et ne se voient pas a
/// l'ecran — ils se comptent.
class RadioFactice implements BleRadio {
  /// Combien de fois le Dart a traverse la frontiere native pour demander
  /// « as-tu constate quelqu'un ? ».
  ///
  /// ⚠️ **C'est le compteur du defaut du 2026-08-28** : ce balayage tournait
  /// toutes les deux secondes meme les deux interrupteurs eteints. Rien ne le
  /// signalait — l'app se comportait exactement comme si tout allait bien.
  int sightingsLues = 0;

  /// Combien de battements de coeur de la decouverte ont ete poses.
  int battements = 0;

  final _flux = StreamController<RadioEvent>.broadcast();

  /// Combien de fois un plan d'émission a été déposé.
  int plans = 0;

  /// Combien de fois une table de reconnaissance a été déposée.
  int tables = 0;

  /// Combien de jetons par créneau porte la dernière table déposée. **Zéro =
  /// table vide**, c'est-à-dire « je ne reconnais plus personne » — un message
  /// qui doit être ENVOYÉ, pas déduit d'un silence.
  int? derniereTablePerSlot;

  int demarrages = 0;

  /// Combien de fois la radio a été **arrêtée**. C'est ce chiffre qui prouve
  /// qu'un interrupteur ne coupe pas la fonction de l'autre.
  int arrets = 0;

  /// Les octets de type du dernier plan déposé : `1` = identifiant public,
  /// `2` = jeton d'ami. **C'est la seule façon de voir ce qu'on crie vraiment.**
  Uint8List? derniersTypes;

  /// Fait échouer le dépôt du plan, pour éprouver le rétablissement.
  bool refusePlan = false;

  @override
  Stream<RadioEvent> events() => _flux.stream;

  @override
  Future<RadioStatus> probe() async => const RadioIdle();

  /// Le dernier identifiant sur lequel la radio a été démarrée. **C'est la
  /// seule façon de voir ce qu'on crie avant que le plan prenne le relais.**
  Uint8List? derniereAmorce;

  @override
  Future<void> start(Uint8List advertId) async {
    demarrages++;
    derniereAmorce = advertId;
  }

  @override
  Future<void> stop() async => arrets++;

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<int> setAdvertPlan({
    required Uint8List tokens,
    required Uint8List types,
    required int fromSlot,
    required int slotMillis,
    required int slotCount,
    required int perSlot,
    required int tokenLength,
  }) async {
    if (refusePlan) throw StateError('service absent');
    plans++;
    derniersTypes = types;
    return 0;
  }

  @override
  Future<void> setRecognitionTable({
    required int tableId,
    required Uint8List tokens,
    required int fromSlot,
    required int slotMillis,
    required int slotCount,
    required int perSlot,
    required int tokenLength,
  }) async {
    tables++;
    derniereTablePerSlot = perSlot;
  }

  @override
  Future<List<Map<String, dynamic>>> takeSightings() async {
    sightingsLues++;
    return const [];
  }

  @override
  Future<void> publicHeartbeat() async => battements++;

  @override
  Future<Map<String, dynamic>> stats() async => const {};

  Future<void> fermer() => _flux.close();
}
