import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Identité cryptographique locale du ping (chantier BLE 2026-07-13).
///
/// - **Clé d'appareil Ed25519** : signe les certificats de croisement, les
///   demandes d'amis co-signées et le mini-profil. Le seed vit dans le
///   Keystore Android (flutter_secure_storage).
/// - **Clé de diffusion (broadcastKey)** : secret 32 octets qui engendre
///   l'ID ROTATIF diffusé en BLE — ID = HMAC-SHA256(broadcastKey, créneau
///   de 15 min) tronqué à 16 octets. Un tiers qui scanne voit un code qui
///   change 4×/heure : pistage impossible. Les AMIS reçoivent la clé (via
///   la table `device_keys`, RLS connexions) et reconnaissent l'ID
///   silencieusement, sans serveur ni connexion.
class ProximityIdentity {
  ProximityIdentity();

  static const _storage = FlutterSecureStorage();
  static const _seedKey = 'nv_ed25519_seed';
  static const _broadcastKey = 'nv_broadcast_key';

  /// Durée d'un créneau de rotation (~15 min, « comme Google »).
  static const slotDuration = Duration(minutes: 15);

  SimpleKeyPair? _keyPair;
  Uint8List? _broadcast;

  Future<void> _ensureLoaded() async {
    if (_keyPair != null && _broadcast != null) return;
    final ed = Ed25519();
    final storedSeed = await _storage.read(key: _seedKey);
    if (storedSeed != null) {
      _keyPair = await ed.newKeyPairFromSeed(base64Decode(storedSeed));
    } else {
      final pair = await ed.newKeyPair();
      final seed = await pair.extractPrivateKeyBytes();
      await _storage.write(key: _seedKey, value: base64Encode(seed));
      _keyPair = pair;
    }
    final storedBroadcast = await _storage.read(key: _broadcastKey);
    if (storedBroadcast != null) {
      _broadcast = base64Decode(storedBroadcast);
    } else {
      final rnd = Random.secure();
      final fresh = Uint8List.fromList(
        List.generate(32, (_) => rnd.nextInt(256)),
      );
      await _storage.write(key: _broadcastKey, value: base64Encode(fresh));
      _broadcast = fresh;
    }
  }

  Future<Uint8List> edPublicKey() async {
    await _ensureLoaded();
    final pub = await _keyPair!.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  Future<Uint8List> broadcastKey() async {
    await _ensureLoaded();
    return _broadcast!;
  }

  /// Signe [message] avec la clé d'appareil.
  Future<Uint8List> sign(List<int> message) async {
    await _ensureLoaded();
    final sig = await Ed25519().sign(message, keyPair: _keyPair!);
    return Uint8List.fromList(sig.bytes);
  }

  static Future<bool> verify(
    List<int> message,
    Uint8List signature,
    Uint8List publicKey,
  ) {
    return Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  static int slotIndex(DateTime at) =>
      at.toUtc().millisecondsSinceEpoch ~/ slotDuration.inMilliseconds;

  /// ID rotatif d'un créneau pour une clé de diffusion donnée.
  static Future<Uint8List> rotatingId(Uint8List broadcastKey, int slot) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('nv-slot-$slot'),
      secretKey: SecretKey(broadcastKey),
    );
    return Uint8List.fromList(mac.bytes.sublist(0, 16));
  }

  /// MON ID rotatif pour le créneau courant.
  Future<Uint8List> currentRotatingId() async {
    await _ensureLoaded();
    return rotatingId(_broadcast!, slotIndex(DateTime.now()));
  }
}

/// Ce dont le réseau a besoin d'un carnet d'amis — et rien de plus.
///
/// Extrait le 2026-08-16 pour que `PeerNetwork` soit testable : `FriendKeyBook`
/// écrit dans le répertoire de l'application, indisponible en test unitaire. Une
/// couche qu'on ne peut pas faire tourner sans téléphone est une couche qu'on ne
/// teste jamais — et c'est exactement ce qui a laissé passer les treize défauts
/// du diagnostic.
abstract class FriendKeyStore {
  Future<Map<String, FriendKeys>> all();
  Future<void> put(FriendKeys keys);
  Future<void> remove(String userId);
  Future<Map<String, FriendKeys>> rotatingIndex(int slot);

  /// Remplace **tout** le carnet par [friends].
  ///
  /// ⚠️ **Indispensable pour qu'un ami retiré cesse d'en être un.** `put` seul
  /// ne fait qu'ajouter : sans remplacement, une amitié rompue côté serveur
  /// resterait vraie sur l'appareil **pour toujours** — on continuerait de
  /// reconnaître la personne à son ID rotatif et de la présenter comme une
  /// amie. Un carnet qui ne sait qu'ajouter n'est pas une source de vérité,
  /// c'est une archive.
  Future<void> replace(Iterable<FriendKeys> friends);

  /// Prévient quand le carnet change.
  ///
  /// ⚠️ **C'est la pièce qui manquait le 2026-08-17.** La synchronisation
  /// écrivait les clés téléchargées, et **rien ne le disait** : l'index rotatif
  /// du réseau, construit une fois au démarrage, ne les voyait jamais. Un ami
  /// restait un inconnu jusqu'au prochain lancement de l'app.
  Listenable get changes;

  /// Oublie TOUT.
  ///
  /// ⚠️ **Indispensable au changement de compte.** Les clés de diffusion des
  /// amis vivent dans un fichier local : sans effacement, un compte B ouvert
  /// sur le même appareil reconnaîtrait **silencieusement** les amis du compte
  /// A, sans qu'aucun serveur ne l'ait autorisé. Pour une app dont la thèse est
  /// le cercle restreint, c'est une fuite, pas un désagrément.
  Future<void> clear();
}

/// Carnet local des clés de reconnaissance des AMIS (+ instantané de profil) :
/// permet d'identifier un ami depuis son ID rotatif, **hors ligne**, sans
/// poignée de main. Alimenté par la table `device_keys` quand internet est là,
/// et directement en BLE quand on devient amis sur place.
class FriendKeyBook implements FriendKeyStore {
  FriendKeyBook();

  /// ⚠️ **Un seul exemplaire dans l'app — voir `friendBookProvider`.**
  ///
  /// Ce cache est ce qui rend le carnet rapide, et c'est aussi ce qui l'a rendu
  /// faux. Le 2026-08-17, **trois** instances coexistaient (contrôleur,
  /// synchronisation, et le défaut de `PeerNetwork`), chacune avec son cache.
  /// La synchronisation écrivait ses clés sur le disque **avec la sienne** ; les
  /// deux autres avaient déjà chargé le fichier et ne le relisaient jamais.
  ///
  /// Résultat : les clés téléchargées du serveur étaient **invisibles au réseau
  /// qui tourne**, pour toute la durée de vie du processus. Un ami s'affichait
  /// alors comme un inconnu, avec un bouton « demander à se connecter ».
  ///
  /// La cause n'est pas le cache : c'est qu'un objet à état partagé était
  /// construit avec `new` à trois endroits. Il passe donc par un provider, et
  /// `new` ne doit plus apparaître ailleurs que dans les tests.
  Map<String, FriendKeys>? _cache;

  final _changes = _BookNotifier();

  @override
  Listenable get changes => _changes;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final ping = Directory('${dir.path}${Platform.pathSeparator}ping');
    if (!await ping.exists()) await ping.create(recursive: true);
    return File('${ping.path}${Platform.pathSeparator}friend_keys.json');
  }

  @override
  Future<Map<String, FriendKeys>> all() async {
    if (_cache != null) return _cache!;
    try {
      final file = await _file();
      if (!await file.exists()) return _cache = {};
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return _cache = raw.map(
        (k, v) => MapEntry(k, FriendKeys.fromJson(v as Map<String, dynamic>)),
      );
    } catch (_) {
      return _cache = {};
    }
  }

  @override
  Future<void> put(FriendKeys keys) async {
    final map = await all();
    map[keys.userId] = keys;
    await _save(map);
  }

  @override
  Future<void> remove(String userId) async {
    final map = await all();
    if (map.remove(userId) != null) await _save(map);
  }

  @override
  Future<void> replace(Iterable<FriendKeys> friends) async {
    final map = {for (final f in friends) f.userId: f};
    final before = await all();
    // Rien n'a changé : ne pas réveiller tout le monde pour rien. Une synchro
    // tourne à chaque croisement, et reconstruire l'index rotatif coûte un HMAC
    // par ami et par créneau.
    if (before.length == map.length &&
        before.keys.every(map.containsKey) &&
        before.entries.every((e) => e.value.sameAs(map[e.key]!))) {
      return;
    }
    await _save(map);
  }

  Future<void> _save(Map<String, FriendKeys> map) async {
    _cache = map;
    final file = await _file();
    await file.writeAsString(
      jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );
    _changes.ping();
  }

  /// Table de correspondance ID rotatif (hex) → ami, pour les créneaux
  /// [slot-1, slot, slot+1] (tolérance d'horloge entre appareils).
  @override
  Future<Map<String, FriendKeys>> rotatingIndex(int slot) async {
    final friends = await all();
    final index = <String, FriendKeys>{};
    for (final friend in friends.values) {
      for (final s in [slot - 1, slot, slot + 1]) {
        final id = await ProximityIdentity.rotatingId(friend.broadcastKey, s);
        index[_hex(id)] = friend;
      }
    }
    return index;
  }

  @override
  Future<void> clear() async {
    _cache = {};
    final file = await _file();
    if (await file.exists()) await file.delete();
    _changes.ping();
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Sous-classe minuscule : `notifyListeners` est protégée, seule une classe
/// dérivée peut l'appeler. Contourner par un `ignore:` marcherait aussi, et
/// laisserait derrière lui une entorse à expliquer à chaque relecture.
class _BookNotifier extends ChangeNotifier {
  void ping() => notifyListeners();
}

class FriendKeys {
  const FriendKeys({
    required this.userId,
    required this.username,
    this.tagName,
    this.avatarUrl,
    required this.edPublicKey,
    required this.broadcastKey,
  });

  final String userId;
  final String username;
  final String? tagName;
  final String? avatarUrl;
  final Uint8List edPublicKey;
  final Uint8List broadcastKey;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'tagName': tagName,
    'avatarUrl': avatarUrl,
    'edPub': base64Encode(edPublicKey),
    'broadcast': base64Encode(broadcastKey),
  };

  factory FriendKeys.fromJson(Map<String, dynamic> json) => FriendKeys(
    userId: json['userId'] as String,
    username: json['username'] as String,
    tagName: json['tagName'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    edPublicKey: base64Decode(json['edPub'] as String),
    broadcastKey: base64Decode(json['broadcast'] as String),
  );

  /// Même contenu ? Sert à `replace` pour ne pas annoncer un changement qui
  /// n'en est pas un — la synchro tourne à chaque croisement, et reconstruire
  /// l'index rotatif coûte un HMAC par ami et par créneau.
  bool sameAs(FriendKeys other) =>
      userId == other.userId &&
      username == other.username &&
      tagName == other.tagName &&
      avatarUrl == other.avatarUrl &&
      _sameBytes(edPublicKey, other.edPublicKey) &&
      _sameBytes(broadcastKey, other.broadcastKey);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
