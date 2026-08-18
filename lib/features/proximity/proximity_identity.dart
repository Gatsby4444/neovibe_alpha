import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Identité cryptographique locale du ping.
///
/// - **Clé d'appareil Ed25519** : signe les certificats de croisement, les
///   demandes d'amis co-signées, la poignée de main et le mini-profil. Le seed
///   vit dans le Keystore Android.
/// - **Clé de diffusion** : secret 32 octets qui engendre l'ID ROTATIF diffusé
///   en BLE — `ID = HMAC-SHA256(clé, créneau de 15 min)` tronqué à 16 octets.
///   Un tiers qui scanne voit un code qui change 4×/heure. Les AMIS reçoivent
///   la clé (table `device_keys`, RLS restreinte aux connexions) et
///   reconnaissent l'ID **hors ligne, sans serveur ni poignée de main**.
///
/// ## ⚠️ Deux défauts corrigés le 2026-08-18
///
/// **1. Cinq instances, cinq caches, et une course au premier lancement.**
/// Cette classe se construisait avec `new` dans le superviseur, le contrôleur,
/// la synchro, `PeerNetwork` et **chaque** `SecureChannel`. `_ensureLoaded`
/// n'avait aucun verrou : au tout premier démarrage, deux instances lancées en
/// parallèle ne trouvaient rien en stockage, **généraient chacune leur clé** et
/// l'écrivaient toutes les deux. On pouvait donc diffuser un ID dérivé de la
/// clé A pendant que le serveur recevait la clé B — nos amis ne nous
/// reconnaissaient jamais — ou signer la poignée de main avec une clé
/// d'appareil et le profil avec une autre, ce qui fait échouer
/// `isPeerDeviceKey` et renvoie « profil non authentifié ». Intermittent,
/// uniquement au premier lancement, indiscernable d'un vrai refus.
///
/// C'est **exactement** le défaut déjà corrigé pour le carnet d'amis le
/// 2026-08-17 ; le raisonnement n'avait simplement jamais été appliqué à
/// l'identité elle-même. D'où [proximityIdentityProvider] et le verrou de
/// [_ensureLoaded].
///
/// **2. La clé de diffusion ne tournait JAMAIS.** Écrite une fois, plus jamais
/// régénérée — pas même par la remise à zéro du ping. Un ex-ami qui l'avait
/// téléchargée nous reconnaissait **à vie**, hors ligne et en silence : la RLS
/// l'empêche de la relire, elle ne reprend pas ce qu'il a déjà. Pour une app
/// dont la thèse est le cercle restreint, retirer un ami ne retirait rien.
class ProximityIdentity {
  ProximityIdentity();

  static const _storage = FlutterSecureStorage();
  static const _seedKey = 'nv_ed25519_seed';

  /// Ancien format : la clé de diffusion nue, sans date ni précédente.
  static const _legacyBroadcastKey = 'nv_broadcast_key';

  /// Format courant : `{"key":…,"prev":…,"at":…}`.
  static const _broadcastKey = 'nv_broadcast_v2';

  /// Durée d'un créneau de rotation de l'ID diffusé (~15 min).
  static const slotDuration = Duration(minutes: 15);

  /// Durée de vie d'une clé de diffusion (décision de Jay, 2026-08-18).
  static const rotationPeriod = Duration(days: 7);

  SimpleKeyPair? _keyPair;
  Uint8List? _broadcast;
  Uint8List? _previous;
  DateTime? _rotatedAt;

  /// ⚠️ **Le verrou, et c'est tout le correctif de la course.**
  ///
  /// Un booléen `_loaded` ne suffit pas : entre le moment où l'on constate
  /// qu'il est faux et celui où on l'écrit, il y a deux `await`. Mémoriser la
  /// **promesse** fait attendre le second appelant au lieu de le laisser
  /// refaire le travail.
  Future<void>? _loading;

  Future<void> _ensureLoaded() {
    final pending = _loading;
    if (pending != null) return pending;
    final started = _load();
    _loading = started;
    // Un échec ne doit pas figer l'objet dans un état inutilisable : on rouvre
    // la porte pour la tentative suivante.
    return started.catchError((Object e) {
      _loading = null;
      throw e;
    });
  }

  Future<void> _load() async {
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

    final stored = await _storage.read(key: _broadcastKey);
    if (stored != null) {
      final map = jsonDecode(stored) as Map<String, dynamic>;
      _broadcast = base64Decode(map['key'] as String);
      final prev = map['prev'] as String?;
      _previous = prev == null ? null : base64Decode(prev);
      _rotatedAt = DateTime.parse(map['at'] as String);
      return;
    }

    // Reprise de l'ancien format : la clé en place reste valable, on lui donne
    // seulement une date de naissance. La dater d'aujourd'hui plutôt que de
    // l'inconnu évite de faire tourner tout le parc au premier lancement de
    // cette version.
    final legacy = await _storage.read(key: _legacyBroadcastKey);
    if (legacy != null) {
      _broadcast = base64Decode(legacy);
      _previous = null;
      _rotatedAt = DateTime.now().toUtc();
      await _persistBroadcast();
      await _storage.delete(key: _legacyBroadcastKey);
      return;
    }

    _broadcast = _freshSecret();
    _previous = null;
    _rotatedAt = DateTime.now().toUtc();
    await _persistBroadcast();
  }

  static Uint8List _freshSecret() {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
  }

  Future<void> _persistBroadcast() async {
    await _storage.write(
      key: _broadcastKey,
      value: jsonEncode({
        'key': base64Encode(_broadcast!),
        if (_previous != null) 'prev': base64Encode(_previous!),
        'at': _rotatedAt!.toIso8601String(),
      }),
    );
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

  /// La clé précédente, tant qu'elle vaut encore.
  ///
  /// ⚠️ **Sans elle, chaque rotation aveuglerait tous nos amis** jusqu'à leur
  /// prochaine synchronisation : ils indexeraient une clé que nous n'utilisons
  /// plus. On publie donc les deux, et l'index d'en face couvre les deux.
  Future<Uint8List?> previousBroadcastKey() async {
    await _ensureLoaded();
    return _previous;
  }

  Future<DateTime> broadcastRotatedAt() async {
    await _ensureLoaded();
    return _rotatedAt!;
  }

  /// Fait tourner la clé si elle a dépassé [rotationPeriod]. Rend `true` si
  /// elle a tourné.
  Future<bool> rotateBroadcastIfDue() async {
    await _ensureLoaded();
    if (DateTime.now().toUtc().difference(_rotatedAt!) < rotationPeriod) {
      return false;
    }
    await rotateBroadcast(keepPrevious: true);
    return true;
  }

  /// Fait tourner la clé maintenant.
  ///
  /// [keepPrevious] décide de ce qu'on abandonne :
  ///
  /// - `true` (rotation périodique) : on continue de publier l'ancienne, donc
  ///   **aucun ami ne nous perd**, même s'il n'a pas encore synchronisé ;
  /// - `false` (**révocation**) : l'ancienne est jetée. Celui qui vient de
  ///   perdre le droit de nous reconnaître devient aveugle immédiatement — et
  ///   nos autres amis aussi, jusqu'à leur prochaine synchronisation. C'est le
  ///   prix, et il est assumé : la synchro tourne au lancement de l'app et à
  ///   chaque croisement.
  Future<void> rotateBroadcast({required bool keepPrevious}) async {
    await _ensureLoaded();
    _previous = keepPrevious ? _broadcast : null;
    _broadcast = _freshSecret();
    _rotatedAt = DateTime.now().toUtc();
    await _persistBroadcast();
  }

  /// Oublie **toute** l'identité de cet appareil.
  ///
  /// ⚠️ **Indispensable au changement de compte, et personne ne le faisait.**
  /// La clé de diffusion ne dépendait pas du compte connecté : après une
  /// déconnexion, l'appareil continuait de diffuser l'ID rotatif du compte
  /// précédent. Les amis de A voyaient donc « A est là » alors que B utilisait
  /// le téléphone — la même fuite que le carnet d'amis non effacé, corrigée le
  /// 2026-08-17, mais un cran plus bas et jamais vue.
  Future<void> forget() async {
    // ⚠️ On attend un chargement déjà lancé avant d'effacer : sinon il finirait
    // APRÈS nous et réinstallerait en mémoire des clés que le stockage n'a plus.
    try {
      await _loading;
    } catch (_) {
      // Un chargement en échec n'a rien laissé derrière lui.
    }
    _loading = null;
    _keyPair = null;
    _broadcast = null;
    _previous = null;
    _rotatedAt = null;
    await _storage.delete(key: _seedKey);
    await _storage.delete(key: _broadcastKey);
    await _storage.delete(key: _legacyBroadcastKey);
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

/// **L'** identité de l'appareil. Une seule, comme le carnet d'amis.
///
/// ⚠️ **Ne jamais écrire `ProximityIdentity()` ailleurs que dans un test.**
/// Voir l'en-tête de la classe : cinq instances coexistaient, avec une course
/// au premier lancement qui pouvait faire diverger la clé diffusée de la clé
/// publiée au serveur.
final proximityIdentityProvider = Provider<ProximityIdentity>(
  (ref) => ProximityIdentity(),
);

/// Ce dont le réseau a besoin d'un carnet d'amis — et rien de plus.
abstract class FriendKeyStore {
  Future<Map<String, FriendKeys>> all();
  Future<void> put(FriendKeys keys);
  Future<void> remove(String userId);

  /// Table ID rotatif (hex) → ami, pour le créneau [slot] et ses voisins.
  Future<Map<String, FriendKeys>> rotatingIndex(int slot);

  /// Remplace **tout** le carnet.
  ///
  /// ⚠️ **Indispensable pour qu'un ami retiré cesse d'en être un.** `put` seul
  /// n'ajoute que : sans remplacement, une amitié rompue côté serveur resterait
  /// vraie sur l'appareil pour toujours. Un carnet qui ne sait qu'ajouter n'est
  /// pas une source de vérité, c'est une archive.
  Future<void> replace(Iterable<FriendKeys> friends);

  /// Prévient quand le carnet change — sans quoi l'index rotatif du réseau ne
  /// verrait jamais les clés téléchargées après son démarrage.
  Listenable get changes;

  /// Oublie TOUT (changement de compte).
  Future<void> clear();
}

/// Carnet local des clés de reconnaissance des AMIS : identifier un ami depuis
/// son ID rotatif, **hors ligne**, sans poignée de main.
class FriendKeyBook implements FriendKeyStore {
  FriendKeyBook();

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
    // Rien n'a changé : ne pas réveiller tout le monde pour rien. La synchro
    // tourne à chaque croisement, et reconstruire l'index rotatif coûte deux
    // HMAC par ami et par créneau.
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
  /// `[slot-1, slot, slot+1]` (tolérance d'horloge) **et pour les DEUX clés**
  /// de chaque ami — la courante et la précédente.
  ///
  /// ⚠️ La clé précédente est ce qui rend une rotation indolore : un ami qui a
  /// changé de clé il y a une heure reste reconnu même si nous n'avons pas
  /// encore synchronisé.
  @override
  Future<Map<String, FriendKeys>> rotatingIndex(int slot) async {
    final friends = await all();
    final index = <String, FriendKeys>{};
    for (final friend in friends.values) {
      for (final key in friend.broadcastKeys) {
        for (final s in [slot - 1, slot, slot + 1]) {
          final id = await ProximityIdentity.rotatingId(key, s);
          index[hex(id)] = friend;
        }
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

  /// Représentation hexadécimale, **la seule de l'app**.
  ///
  /// Elle existait en quatre exemplaires privés (réseau, carnet, doubles de
  /// test), tous identiques. Quatre copies d'une conversion sont quatre
  /// occasions de diverger sur la casse ou le remplissage.
  static String hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// `notifyListeners` est protégée : seule une sous-classe peut l'appeler.
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
    this.previousBroadcastKey,
  });

  final String userId;
  final String username;
  final String? tagName;
  final String? avatarUrl;
  final Uint8List edPublicKey;
  final Uint8List broadcastKey;

  /// La clé d'avant sa dernière rotation, si elle vaut encore.
  final Uint8List? previousBroadcastKey;

  /// Les clés sous lesquelles cet ami peut se présenter.
  List<Uint8List> get broadcastKeys => [broadcastKey, ?previousBroadcastKey];

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'tagName': tagName,
    'avatarUrl': avatarUrl,
    'edPub': base64Encode(edPublicKey),
    'broadcast': base64Encode(broadcastKey),
    if (previousBroadcastKey != null)
      'broadcastPrev': base64Encode(previousBroadcastKey!),
  };

  factory FriendKeys.fromJson(Map<String, dynamic> json) => FriendKeys(
    userId: json['userId'] as String,
    username: json['username'] as String,
    tagName: json['tagName'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    edPublicKey: base64Decode(json['edPub'] as String),
    broadcastKey: base64Decode(json['broadcast'] as String),
    previousBroadcastKey: json['broadcastPrev'] == null
        ? null
        : base64Decode(json['broadcastPrev'] as String),
  );

  /// Même contenu ? Sert à `replace` pour ne pas annoncer un changement qui
  /// n'en est pas un.
  bool sameAs(FriendKeys other) =>
      userId == other.userId &&
      username == other.username &&
      tagName == other.tagName &&
      avatarUrl == other.avatarUrl &&
      _sameBytes(edPublicKey, other.edPublicKey) &&
      _sameBytes(broadcastKey, other.broadcastKey) &&
      _sameBytes(previousBroadcastKey, other.previousBroadcastKey);

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
