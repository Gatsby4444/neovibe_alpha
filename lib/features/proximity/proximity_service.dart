import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/nearby_user.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/supabase_providers.dart';
import 'ble_link.dart';
import 'ping_store.dart';
import 'proximity_identity.dart';

/// Seuil RSSI grossier — jamais de distance précise (spec 4.2).
const _veryCloseRssi = -60;

/// Un pair est hors de portée après ce délai sans trame.
const _staleAfter = Duration(seconds: 30);

/// Croisement VALIDÉ = contact BLE continu pendant ce délai, puis
/// certificat co-signé (décision Jay 2026-07-13, Q3). En dessous =
/// « presque » (FOMO).
const _certificateAfter = Duration(seconds: 10);

/// Anti-spam Waves : un seul enregistrement par pair par fenêtre.
const _waveCooldown = Duration(hours: 2);

/// Pair NeoVibe à proximité, identifié LOCALEMENT (ami reconnu par son ID
/// rotatif, ou inconnu révélé par la poignée de main chiffrée).
class NearbyPeer {
  const NearbyPeer({
    required this.address,
    required this.snapshot,
    required this.isFriend,
    required this.proximity,
    required this.lastSeen,
  });

  final String address;
  final PingPeerSnapshot snapshot;
  final bool isFriend;
  final ProximityLevel proximity;
  final DateTime lastSeen;

  NearbyPeer copyWith({
    String? address,
    ProximityLevel? proximity,
    DateTime? lastSeen,
  }) => NearbyPeer(
    address: address ?? this.address,
    snapshot: snapshot,
    isFriend: isFriend,
    proximity: proximity ?? this.proximity,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

/// Demande d'ami reçue en BLE, en attente de réponse locale.
class PendingBleFriendRequest {
  const PendingBleFriendRequest({
    required this.fromUserId,
    required this.snapshot,
    required this.payload,
  });
  final String fromUserId;
  final PingPeerSnapshot snapshot;
  final Map<String, dynamic> payload;
}

class ProximityState {
  const ProximityState({
    this.visible = false,
    this.nearby = const {},
    this.incomingFriendRequest,
    this.error,
  });

  /// Visibilité : opt-in explicite, jamais activée au lancement (spec 4.2).
  final bool visible;

  /// userId → pair à proximité.
  final Map<String, NearbyPeer> nearby;
  final PendingBleFriendRequest? incomingFriendRequest;
  final String? error;

  List<NearbyPeer> get nearbyList {
    final list = nearby.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  ProximityState copyWith({
    bool? visible,
    Map<String, NearbyPeer>? nearby,
    PendingBleFriendRequest? incomingFriendRequest,
    bool clearRequest = false,
    String? error,
  }) => ProximityState(
    visible: visible ?? this.visible,
    nearby: nearby ?? this.nearby,
    incomingFriendRequest: clearRequest
        ? null
        : incomingFriendRequest ?? this.incomingFriendRequest,
    error: error,
  );
}

/// Session chiffrée avec un pair (une par lien GATT).
class _PeerSession {
  _PeerSession(this.linkId);
  final String linkId;
  SimpleKeyPair? myEphemeral;
  SecretKey? sessionKey;
  PingPeerSnapshot? peer;
  Uint8List? peerEdPub;
  DateTime openedAt = DateTime.now();
  bool certDone = false;
  bool initiator = false;
}

/// Orchestrateur du ping 100 % BLE (chantier A, décisions Jay 2026-07-13) :
/// découverte locale, reconnaissance silencieuse des amis (IDs rotatifs),
/// poignée de main chiffrée avant tout partage de profil, chat local TTL
/// 12 h, certificats de croisement co-signés (10 s), demandes d'amis
/// co-signées validées par le serveur au retour d'internet.
class ProximityService extends Notifier<ProximityState> {
  BleLink? _link;
  final _identity = ProximityIdentity();
  final _keyBook = FriendKeyBook();

  Timer? _rotationTimer;
  Timer? _housekeeping;
  int _currentSlot = -1;

  /// address → (advertId hex, rssi, lastSeen).
  final _seen = <String, ({String advertHex, int rssi, DateTime at})>{};

  /// advertId hex → ami (reconstruit à chaque créneau).
  Map<String, FriendKeys> _friendIndex = {};

  /// linkId → session.
  final _sessions = <String, _PeerSession>{};

  /// userId → linkId de session établie.
  final _sessionByUser = <String, String>{};

  /// Adresses en cours de connexion (anti-doublon).
  final _connecting = <String>{};

  final _lastWaveAt = <String, DateTime>{};

  String? get _myId => ref.read(currentUserIdProvider);

  @override
  ProximityState build() {
    ref.onDispose(_stopHardware);
    return const ProximityState();
  }

  // ------------------------------------------------------------------
  // Cycle de vie
  // ------------------------------------------------------------------

  Future<void> enable() async {
    if (state.visible) return;
    if (!await _requestPermissions()) {
      state = state.copyWith(error: 'Permissions Bluetooth refusées');
      return;
    }
    try {
      await ref.read(pingStoreProvider).sweep();
      _currentSlot = ProximityIdentity.slotIndex(DateTime.now());
      _friendIndex = await _keyBook.rotatingIndex(_currentSlot);
      _link = BleLink(
        onScan: _onScan,
        onLinkUp: _onLinkUp,
        onLinkDown: _onLinkDown,
        onFrame: _onFrame,
        onError: (m) => state = state.copyWith(error: m),
      );
      await _link!.start(await _identity.currentRotatingId());
      _rotationTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _rotateIfNeeded(),
      );
      _housekeeping = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _tick(),
      );
      await _startForegroundService();
      state = state.copyWith(visible: true, error: null);
      // Au passage (si internet) : clés synchronisées + outbox vidée.
      unawaited(syncWithServer());
    } catch (e) {
      await _stopHardware();
      state = state.copyWith(visible: false, error: 'Bluetooth : $e');
    }
  }

  Future<void> disable() async {
    await _stopHardware();
    state = const ProximityState();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();
    return statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothAdvertise]!.isGranted &&
        statuses[Permission.bluetoothConnect]!.isGranted;
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'NeoVibe est attentif',
      notificationText: 'Détection de proximité active',
      callback: proximityForegroundCallback,
    );
  }

  Future<void> _stopHardware() async {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _housekeeping?.cancel();
    _housekeeping = null;
    _sessions.clear();
    _sessionByUser.clear();
    _connecting.clear();
    _seen.clear();
    try {
      await _link?.stop();
    } catch (_) {}
    _link = null;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Rotation de l'ID diffusé toutes les ~15 min (anti-pistage).
  Future<void> _rotateIfNeeded() async {
    final slot = ProximityIdentity.slotIndex(DateTime.now());
    if (slot == _currentSlot) return;
    _currentSlot = slot;
    _friendIndex = await _keyBook.rotatingIndex(slot);
    try {
      await _link?.updateAdvert(await _identity.currentRotatingId());
    } catch (_) {}
  }

  void _tick() {
    _pruneStale();
    _maybeStartCertificates();
  }

  // ------------------------------------------------------------------
  // Découverte
  // ------------------------------------------------------------------

  Future<void> _onScan(String address, Uint8List advertId, int rssi) async {
    final now = DateTime.now();
    final hex = _hex(advertId);
    _seen[address] = (advertHex: hex, rssi: rssi, at: now);

    final friend = _friendIndex[hex];
    if (friend != null) {
      _upsertNearby(
        NearbyPeer(
          address: address,
          snapshot: PingPeerSnapshot(
            userId: friend.userId,
            username: friend.username,
            tagName: friend.tagName,
            verified: true,
          ),
          isFriend: true,
          proximity: _level(rssi),
          lastSeen: now,
        ),
      );
      unawaited(_maybeWave(friend));
      return;
    }

    // Inconnu : révélation automatique mutuelle (décision A6a) via poignée
    // de main chiffrée. Un seul initiateur (ordre lexical des IDs diffusés)
    // pour éviter les doubles liens.
    final known = state.nearby.values.any(
      (p) => p.address == address && now.difference(p.lastSeen) < _staleAfter,
    );
    if (known) {
      _touchAddress(address, rssi, now);
      return;
    }
    final myHex = _hex(await _identity.currentRotatingId());
    if (myHex.compareTo(hex) >= 0) return; // l'autre initiera
    if (_connecting.contains(address)) return;
    if (_sessions.values.any(
      (s) => s.linkId == address && s.sessionKey != null,
    )) {
      return;
    }
    _connecting.add(address);
    try {
      final linkId = await _link?.connect(address);
      if (linkId != null) {
        final session = _sessions[linkId] ?? _PeerSession(linkId);
        session.initiator = true;
        _sessions[linkId] = session;
        await _sendHello(session);
      }
    } catch (_) {
      // Pair déjà reparti ou connexion refusée : le scan retentera.
    } finally {
      _connecting.remove(address);
    }
  }

  void _touchAddress(String address, int rssi, DateTime now) {
    final updated = Map<String, NearbyPeer>.from(state.nearby);
    for (final entry in updated.entries) {
      if (entry.value.address == address) {
        updated[entry.key] = entry.value.copyWith(
          proximity: _level(rssi),
          lastSeen: now,
        );
      }
    }
    state = state.copyWith(nearby: updated);
  }

  void _upsertNearby(NearbyPeer peer) {
    final updated = Map<String, NearbyPeer>.from(state.nearby);
    updated[peer.snapshot.userId] = peer;
    state = state.copyWith(nearby: updated);
  }

  void _pruneStale() {
    final now = DateTime.now();
    final kept = <String, NearbyPeer>{};
    state.nearby.forEach((id, peer) {
      if (now.difference(peer.lastSeen) < _staleAfter) kept[id] = peer;
    });
    if (kept.length != state.nearby.length) {
      state = state.copyWith(nearby: kept);
    }
    _seen.removeWhere((_, v) => now.difference(v.at) > _staleAfter);
  }

  ProximityLevel _level(int rssi) =>
      rssi >= _veryCloseRssi ? ProximityLevel.veryClose : ProximityLevel.close;

  bool isInRange(String userId) {
    final peer = state.nearby[userId];
    return peer != null &&
        DateTime.now().difference(peer.lastSeen) < _staleAfter;
  }

  // ------------------------------------------------------------------
  // Liens & protocole
  // ------------------------------------------------------------------

  void _onLinkUp(String linkId, bool incoming) {
    _sessions.putIfAbsent(linkId, () => _PeerSession(linkId));
  }

  void _onLinkDown(String linkId) {
    final session = _sessions.remove(linkId);
    final userId = session?.peer?.userId;
    if (userId != null && _sessionByUser[userId] == linkId) {
      _sessionByUser.remove(userId);
    }
  }

  Future<void> _sendJson(String linkId, Map<String, dynamic> frame) async {
    await _link?.send(
      linkId,
      Uint8List.fromList(utf8.encode(jsonEncode(frame))),
    );
  }

  /// Envoie un cadre CHIFFRÉ (AES-GCM, clé de session) sur le lien.
  Future<void> _sendEncrypted(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final key = session.sessionKey;
    if (key == null) throw StateError('Session non établie');
    final aes = AesGcm.with256bits();
    final nonce = aes.newNonce();
    final box = await aes.encrypt(
      utf8.encode(jsonEncode(inner)),
      secretKey: key,
      nonce: nonce,
    );
    await _sendJson(session.linkId, {
      't': 'enc',
      'n': base64Encode(nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    });
  }

  Future<void> _sendHello(_PeerSession session) async {
    final x = X25519();
    session.myEphemeral = await x.newKeyPair();
    final pub = await session.myEphemeral!.extractPublicKey();
    await _sendJson(session.linkId, {
      't': 'hello',
      'x': base64Encode(pub.bytes),
    });
  }

  Future<void> _deriveSession(_PeerSession session, String peerPubB64) async {
    final x = X25519();
    session.myEphemeral ??= await x.newKeyPair();
    final shared = await x.sharedSecretKey(
      keyPair: session.myEphemeral!,
      remotePublicKey: SimplePublicKey(
        base64Decode(peerPubB64),
        type: KeyPairType.x25519,
      ),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    session.sessionKey = await hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode('nv-ping-session-v1'),
    );
  }

  Future<void> _onFrame(String linkId, Uint8List data) async {
    final session = _sessions.putIfAbsent(linkId, () => _PeerSession(linkId));
    Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(utf8.decode(data)) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    try {
      switch (frame['t']) {
        case 'hello':
          await _deriveSession(session, frame['x'] as String);
          final x = await session.myEphemeral!.extractPublicKey();
          await _sendJson(linkId, {
            't': 'helloAck',
            'x': base64Encode(x.bytes),
          });
          await _sendProfile(session);
        case 'helloAck':
          await _deriveSession(session, frame['x'] as String);
          await _sendProfile(session);
        case 'enc':
          final inner = await _decrypt(session, frame);
          if (inner != null) await _onInnerFrame(session, inner);
      }
    } catch (_) {
      // Trame invalide/pair incompatible : on ignore, le lien mourra seul.
    }
  }

  Future<Map<String, dynamic>?> _decrypt(
    _PeerSession session,
    Map<String, dynamic> frame,
  ) async {
    final key = session.sessionKey;
    if (key == null) return null;
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(frame['c'] as String),
          nonce: base64Decode(frame['n'] as String),
          mac: Mac(base64Decode(frame['m'] as String)),
        ),
        secretKey: key,
      );
      return (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Mini-profil : envoyé UNIQUEMENT dans le tunnel chiffré, signé par la
  /// clé d'appareil (révélation automatique mutuelle, décision A6a).
  Future<void> _sendProfile(_PeerSession session) async {
    final me = _myId;
    if (me == null) return;
    final profile = await ref.read(myProfileProvider.future);
    final username = profile?.displayName ?? 'inconnu';
    final tagName = profile?.tagName;
    final edPub = await _identity.edPublicKey();
    final payload = 'nv-profile|$me|$username';
    final sig = await _identity.sign(utf8.encode(payload));
    await _sendEncrypted(session, {
      't': 'profile',
      'userId': me,
      'username': username,
      'tagName': tagName,
      'edPub': base64Encode(edPub),
      'sig': base64Encode(sig),
    });
  }

  Future<void> _onInnerFrame(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    switch (inner['t']) {
      case 'profile':
        await _onPeerProfile(session, inner);
      case 'msg':
        await _onPeerMessage(session, inner);
      case 'certOffer':
        await _onCertOffer(session, inner);
      case 'certFinal':
        await _onCertFinal(session, inner);
      case 'friendReq':
        await _onFriendRequest(session, inner);
      case 'friendAccept':
        await _onFriendAccept(session, inner);
    }
  }

  Future<void> _onPeerProfile(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final userId = inner['userId'] as String;
    final username = inner['username'] as String;
    final edPub = base64Decode(inner['edPub'] as String);
    final sigOk = await ProximityIdentity.verify(
      utf8.encode('nv-profile|$userId|$username'),
      base64Decode(inner['sig'] as String),
      Uint8List.fromList(edPub),
    );
    if (!sigOk) return;
    final snapshot = PingPeerSnapshot(
      userId: userId,
      username: username,
      tagName: inner['tagName'] as String?,
    );
    session.peer = snapshot;
    session.peerEdPub = Uint8List.fromList(edPub);
    _sessionByUser[userId] = session.linkId;
    final seen = _seen[session.linkId];
    _upsertNearby(
      NearbyPeer(
        address: session.linkId,
        snapshot: snapshot,
        isFriend: (await _keyBook.all()).containsKey(userId),
        proximity: _level(seen?.rssi ?? -80),
        lastSeen: DateTime.now(),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Chat local
  // ------------------------------------------------------------------

  /// Envoie un message ping (100 % BLE, jamais serveur). Lève une erreur
  /// parlante si hors de portée ou bloqué par l'anti-spam.
  Future<void> sendMessage(String peerUserId, String text) async {
    final store = ref.read(pingStoreProvider);
    final conv = await store.conversation(peerUserId);
    if ((conv?.unansweredOutgoing ?? 0) >= PingStore.unansweredLimit) {
      throw StateError(
        'Attends une réponse — 3 messages max sans réponse (anti-spam).',
      );
    }
    final session = await _ensureSession(peerUserId);
    final message = PingMessage(
      id: _randomId(),
      mine: true,
      text: text,
      at: DateTime.now(),
    );
    await _sendEncrypted(session, {
      't': 'msg',
      'id': message.id,
      'text': text,
      'ts': message.at.toIso8601String(),
    });
    await store.append(
      peerUserId,
      peer: session.peer ?? _snapshotFor(peerUserId),
      message: message,
    );
  }

  Future<void> _onPeerMessage(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final peer = session.peer;
    if (peer == null) return;
    final message = PingMessage(
      id: inner['id'] as String,
      mine: false,
      text: inner['text'] as String,
      at: DateTime.tryParse(inner['ts'] as String? ?? '') ?? DateTime.now(),
    );
    final accepted = await ref
        .read(pingStoreProvider)
        .append(peer.userId, peer: peer, message: message);
    if (accepted) {
      await NotificationService.instance.show(
        NotifChannel.proximity,
        peer.displayName,
        message.text,
        payload: 'ping:${peer.userId}',
      );
    }
  }

  /// Session existante avec [peerUserId], sinon connexion + poignée de main
  /// (le pair doit être en portée).
  Future<_PeerSession> _ensureSession(String peerUserId) async {
    final existingLink = _sessionByUser[peerUserId];
    if (existingLink != null) {
      final session = _sessions[existingLink];
      if (session?.sessionKey != null) return session!;
    }
    final peer = state.nearby[peerUserId];
    if (peer == null) {
      throw StateError('Hors de portée — recroisez-vous pour discuter.');
    }
    final linkId = await _link?.connect(peer.address);
    if (linkId == null) throw StateError('Connexion BLE impossible');
    final session = _sessions.putIfAbsent(linkId, () => _PeerSession(linkId));
    session.initiator = true;
    await _sendHello(session);
    // Attend l'établissement (helloAck + profil), 5 s max.
    for (var i = 0; i < 50; i++) {
      if (session.sessionKey != null && session.peer != null) return session;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Le pair ne répond pas');
  }

  PingPeerSnapshot _snapshotFor(String userId) {
    final nearby = state.nearby[userId];
    return nearby?.snapshot ??
        PingPeerSnapshot(userId: userId, username: 'inconnu');
  }

  // ------------------------------------------------------------------
  // Certificats de croisement (10 s de contact continu)
  // ------------------------------------------------------------------

  void _maybeStartCertificates() {
    final now = DateTime.now();
    for (final session in _sessions.values) {
      if (session.certDone ||
          !session.initiator ||
          session.sessionKey == null ||
          session.peer == null) {
        continue;
      }
      if (now.difference(session.openedAt) >= _certificateAfter) {
        session.certDone = true; // une seule tentative par session
        unawaited(_offerCertificate(session));
      }
    }
  }

  Future<void> _offerCertificate(_PeerSession session) async {
    final me = _myId;
    final peer = session.peer;
    if (me == null || peer == null) return;
    final ts = DateTime.now().toUtc().toIso8601String();
    final payload = 'nv-cert|$me|${peer.userId}|$ts';
    final sig = await _identity.sign(utf8.encode(payload));
    await _sendEncrypted(session, {
      't': 'certOffer',
      'a': me,
      'b': peer.userId,
      'ts': ts,
      'sigA': base64Encode(sig),
      'edPubA': base64Encode(await _identity.edPublicKey()),
    });
  }

  Future<void> _onCertOffer(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final me = _myId;
    final peer = session.peer;
    if (me == null || peer == null) return;
    final a = inner['a'] as String;
    final b = inner['b'] as String;
    final ts = inner['ts'] as String;
    if (a != peer.userId || b != me) return;
    final payload = 'nv-cert|$a|$b|$ts';
    final okA = await ProximityIdentity.verify(
      utf8.encode(payload),
      base64Decode(inner['sigA'] as String),
      Uint8List.fromList(base64Decode(inner['edPubA'] as String)),
    );
    if (!okA) return;
    final sigB = await _identity.sign(utf8.encode(payload));
    final cert = {
      'a': a,
      'b': b,
      'ts': ts,
      'sigA': inner['sigA'],
      'sigB': base64Encode(sigB),
      'edPubA': inner['edPubA'],
      'edPubB': base64Encode(await _identity.edPublicKey()),
    };
    await _sendEncrypted(session, {'t': 'certFinal', ...cert});
    session.certDone = true;
    await _storeEncounter(peer, cert);
  }

  Future<void> _onCertFinal(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final me = _myId;
    final peer = session.peer;
    if (me == null || peer == null) return;
    if (inner['a'] != me || inner['b'] != peer.userId) return;
    final payload = 'nv-cert|${inner['a']}|${inner['b']}|${inner['ts']}';
    final okB = await ProximityIdentity.verify(
      utf8.encode(payload),
      base64Decode(inner['sigB'] as String),
      Uint8List.fromList(base64Decode(inner['edPubB'] as String)),
    );
    if (!okB) return;
    final cert = Map<String, dynamic>.from(inner)..remove('t');
    await _storeEncounter(peer, cert);
  }

  Future<void> _storeEncounter(
    PingPeerSnapshot peer,
    Map<String, dynamic> cert,
  ) async {
    final store = ref.read(pingStoreProvider);
    await store.addEncounter(
      LocalEncounter(peer: peer, at: DateTime.now(), certificate: cert),
    );
    // Croisements remontés au serveur (décision A7a : Jay veut les features
    // de rétention). Le serveur ne accepte QUE des certificats co-signés.
    await store.enqueue({'type': 'encounter', 'certificate': cert});
    unawaited(syncWithServer());
  }

  // ------------------------------------------------------------------
  // Demandes d'amis co-signées (BLE d'abord, serveur ensuite)
  // ------------------------------------------------------------------

  Future<void> sendFriendRequest(String peerUserId) async {
    final me = _myId;
    if (me == null) return;
    final session = await _ensureSession(peerUserId);
    final ts = DateTime.now().toUtc().toIso8601String();
    final payload = 'nv-friend|$me|$peerUserId|$ts';
    final sig = await _identity.sign(utf8.encode(payload));
    await _sendEncrypted(session, {
      't': 'friendReq',
      'from': me,
      'to': peerUserId,
      'ts': ts,
      'sigFrom': base64Encode(sig),
      'edPubFrom': base64Encode(await _identity.edPublicKey()),
      'broadcastFrom': base64Encode(await _identity.broadcastKey()),
    });
  }

  Future<void> _onFriendRequest(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final me = _myId;
    final peer = session.peer;
    if (me == null || peer == null) return;
    if (inner['from'] != peer.userId || inner['to'] != me) return;
    final payload = 'nv-friend|${inner['from']}|${inner['to']}|${inner['ts']}';
    final ok = await ProximityIdentity.verify(
      utf8.encode(payload),
      base64Decode(inner['sigFrom'] as String),
      Uint8List.fromList(base64Decode(inner['edPubFrom'] as String)),
    );
    if (!ok) return;
    state = state.copyWith(
      incomingFriendRequest: PendingBleFriendRequest(
        fromUserId: peer.userId,
        snapshot: peer,
        payload: inner,
      ),
    );
  }

  /// Répond à la demande d'ami BLE affichée. Accepter = co-signature +
  /// échange des clés de reconnaissance + envoi au serveur (qui vérifie les
  /// DEUX signatures — états divergents impossibles, décision A1).
  Future<void> respondToFriendRequest({required bool accept}) async {
    final me = _myId;
    final pending = state.incomingFriendRequest;
    if (me == null || pending == null) return;
    state = state.copyWith(clearRequest: true);
    if (!accept) return;
    final linkId = _sessionByUser[pending.fromUserId];
    final session = linkId != null ? _sessions[linkId] : null;
    if (session == null) return;
    final req = pending.payload;
    final acceptPayload =
        'nv-friend-accept|${req['from']}|${req['to']}|${req['ts']}';
    final sigTo = await _identity.sign(utf8.encode(acceptPayload));
    final record = {
      'from': req['from'],
      'to': req['to'],
      'ts': req['ts'],
      'sigFrom': req['sigFrom'],
      'sigTo': base64Encode(sigTo),
    };
    await _sendEncrypted(session, {
      't': 'friendAccept',
      ...record,
      'edPubTo': base64Encode(await _identity.edPublicKey()),
      'broadcastTo': base64Encode(await _identity.broadcastKey()),
    });
    // Clés de l'ami (reçues avec la demande) → reconnaissance immédiate.
    await _keyBook.put(
      FriendKeys(
        userId: pending.fromUserId,
        username: pending.snapshot.username,
        tagName: pending.snapshot.tagName,
        edPublicKey: Uint8List.fromList(
          base64Decode(req['edPubFrom'] as String),
        ),
        broadcastKey: Uint8List.fromList(
          base64Decode(req['broadcastFrom'] as String),
        ),
      ),
    );
    await ref.read(pingStoreProvider).enqueue({
      'type': 'connection',
      'record': record,
    });
    unawaited(syncWithServer());
  }

  Future<void> _onFriendAccept(
    _PeerSession session,
    Map<String, dynamic> inner,
  ) async {
    final me = _myId;
    final peer = session.peer;
    if (me == null || peer == null) return;
    if (inner['from'] != me || inner['to'] != peer.userId) return;
    final acceptPayload =
        'nv-friend-accept|${inner['from']}|${inner['to']}|${inner['ts']}';
    final ok = await ProximityIdentity.verify(
      utf8.encode(acceptPayload),
      base64Decode(inner['sigTo'] as String),
      Uint8List.fromList(base64Decode(inner['edPubTo'] as String)),
    );
    if (!ok) return;
    await _keyBook.put(
      FriendKeys(
        userId: peer.userId,
        username: peer.username,
        tagName: peer.tagName,
        edPublicKey: Uint8List.fromList(
          base64Decode(inner['edPubTo'] as String),
        ),
        broadcastKey: Uint8List.fromList(
          base64Decode(inner['broadcastTo'] as String),
        ),
      ),
    );
    final record = {
      'from': inner['from'],
      'to': inner['to'],
      'ts': inner['ts'],
      'sigFrom': inner['sigFrom'],
      'sigTo': inner['sigTo'],
    };
    await ref.read(pingStoreProvider).enqueue({
      'type': 'connection',
      'record': record,
    });
    unawaited(syncWithServer());
  }

  // ------------------------------------------------------------------
  // Waves « le presque » (amis croisés sans interaction)
  // ------------------------------------------------------------------

  Future<void> _maybeWave(FriendKeys friend) async {
    final last = _lastWaveAt[friend.userId];
    if (last != null && DateTime.now().difference(last) < _waveCooldown) {
      return;
    }
    _lastWaveAt[friend.userId] = DateTime.now();
    final profile = ref.read(myProfileProvider).value;
    final realtime = profile?.realtimeWaves ?? false;
    final notifyAfter = realtime
        ? DateTime.now()
        : DateTime.now().add(const Duration(minutes: 45));
    await NotificationService.instance.schedule(
      NotifChannel.waves,
      'Le presque…',
      '${friend.username} est passé tout près de toi.',
      notifyAfter,
    );
    await ref.read(pingStoreProvider).enqueue({
      'type': 'wave',
      'peerId': friend.userId,
      'notifyAfter': notifyAfter.toUtc().toIso8601String(),
    });
    unawaited(syncWithServer());
  }

  // ------------------------------------------------------------------
  // Synchronisation serveur (opportuniste, au retour d'internet)
  // ------------------------------------------------------------------

  var _syncing = false;

  /// 1) Publie mes clés d'appareil ; 2) rapatrie les clés de reconnaissance
  /// de mes amis ; 3) vide l'outbox (croisements certifiés, connexions
  /// co-signées, waves). Sans internet : silencieux, on réessaiera.
  Future<void> syncWithServer() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final client = ref.read(supabaseProvider);
      final me = _myId;
      if (me == null) return;

      await client.from('device_keys').upsert({
        'user_id': me,
        'ed_pub': base64Encode(await _identity.edPublicKey()),
        'broadcast_key': base64Encode(await _identity.broadcastKey()),
      });

      final rows =
          await client.from('device_keys').select().neq('user_id', me) as List;
      for (final rawRow in rows) {
        final row = rawRow as Map<String, dynamic>;
        final profileRow = await client
            .from('profiles')
            .select('id, display_name, tag_name, avatar_url')
            .eq('id', row['user_id'] as String)
            .maybeSingle();
        if (profileRow == null) continue;
        await _keyBook.put(
          FriendKeys(
            userId: row['user_id'] as String,
            username: profileRow['display_name'] as String,
            tagName: profileRow['tag_name'] as String?,
            avatarUrl: profileRow['avatar_url'] as String?,
            edPublicKey: Uint8List.fromList(
              base64Decode(row['ed_pub'] as String),
            ),
            broadcastKey: Uint8List.fromList(
              base64Decode(row['broadcast_key'] as String),
            ),
          ),
        );
      }
      _friendIndex = await _keyBook.rotatingIndex(_currentSlot);

      final store = ref.read(pingStoreProvider);
      final pending = await store.outbox();
      final remaining = <Map<String, dynamic>>[];
      for (final item in pending) {
        try {
          switch (item['type']) {
            case 'encounter':
              await client.rpc(
                'report_encounter',
                params: {'cert': item['certificate']},
              );
            case 'connection':
              await client.rpc(
                'submit_ble_connection',
                params: {'record': item['record']},
              );
            case 'wave':
              await client.from('waves').insert({
                'user_id': me,
                'peer_id': item['peerId'],
                'notify_after': item['notifyAfter'],
              });
          }
        } catch (_) {
          remaining.add(item); // réseau ou erreur : on garde pour plus tard
        }
      }
      await store.replaceOutbox(remaining);
    } catch (_) {
      // Hors ligne : tout reste dans l'outbox.
    } finally {
      _syncing = false;
    }
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _randomId() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }
}

final proximityServiceProvider =
    NotifierProvider<ProximityService, ProximityState>(ProximityService.new);

/// Callback du service de premier plan : maintient le process en vie pour
/// que le scan/advertising continue app fermée (décision Q1b — ⚠ rappel
/// batterie à mesurer, consigne Jay).
@pragma('vm:entry-point')
void proximityForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_NoopTaskHandler());
}

class _NoopTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
