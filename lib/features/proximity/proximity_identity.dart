import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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

/// Carnet local des clés de reconnaissance des AMIS (+ instantané de
/// profil) : permet d'identifier un ami depuis son ID rotatif, hors ligne,
/// sans poignée de main. Alimenté par la table `device_keys` quand internet
/// est là, et directement en BLE quand on devient amis sur place.
class FriendKeyBook {
  FriendKeyBook();

  Map<String, FriendKeys>? _cache;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final ping = Directory('${dir.path}${Platform.pathSeparator}ping');
    if (!await ping.exists()) await ping.create(recursive: true);
    return File('${ping.path}${Platform.pathSeparator}friend_keys.json');
  }

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

  Future<void> put(FriendKeys keys) async {
    final map = await all();
    map[keys.userId] = keys;
    await _save(map);
  }

  Future<void> remove(String userId) async {
    final map = await all();
    if (map.remove(userId) != null) await _save(map);
  }

  Future<void> _save(Map<String, FriendKeys> map) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  /// Table de correspondance ID rotatif (hex) → ami, pour les créneaux
  /// [slot-1, slot, slot+1] (tolérance d'horloge entre appareils).
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

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
}
