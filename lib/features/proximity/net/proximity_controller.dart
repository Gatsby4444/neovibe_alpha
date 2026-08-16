import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../proximity_identity.dart';
import 'peer_network.dart';
import 'presence_tracker.dart';
import 'proximity_journal.dart';
import 'proximity_protocol.dart';
import 'ble_radio.dart';
import 'proximity_supervisor.dart';
import 'radio_status.dart';

/// Ce que l'interface a besoin de savoir, et rien de plus.
class ProximityView {
  const ProximityView({
    required this.runtime,
    this.peers = const [],
    this.requests = const [],
  });

  /// Intention de l'utilisateur + état réel de la radio.
  final ProximityRuntime runtime;

  /// Qui est autour, avec son état d'identification.
  final List<PresencePeer> peers;

  /// Demandes d'amis en attente — **plusieurs**, et **persistantes**.
  final List<PendingFriendRequest> requests;

  List<PresencePeer> get identified =>
      peers.where((p) => p.stage == PresenceStage.identified).toList();

  /// Des appareils sont détectés mais pas encore identifiés.
  ///
  /// C'est ce qui permet de ne plus afficher « personne » pendant qu'une
  /// poignée de main est en cours (défaut B5).
  int get pendingIdentification =>
      peers.where((p) => p.stage != PresenceStage.identified).length;
}

/// Le chef d'orchestre : il branche la radio sur le réseau, et le réseau sur
/// les fonctions du produit.
///
/// ## Ce qu'il porte, et ce qu'il délègue
///
/// Il **décide** (quand certifier un croisement, quoi faire d'une demande
/// d'ami, quand envoyer un wave) et il **range** (magasin local, file d'envoi
/// serveur). Il ne touche ni à la radio, ni au chiffrement, ni au format du fil.
///
/// C'est le seul endroit du système qui connaisse à la fois les règles du
/// produit et l'état du réseau — et il tient en un fichier qu'on peut lire.
class ProximityController extends AsyncNotifier<ProximityView> {
  PeerNetwork? _network;
  StreamSubscription<RadioEvent>? _radioFeed;
  StreamSubscription<PeerEvent>? _peerFeed;
  Timer? _certificates;

  final _journal = ProximityJournal();
  final _identity = ProximityIdentity();
  final _keyBook = FriendKeyBook();

  /// Croisement VALIDÉ = contact continu pendant ce délai (décision de Jay,
  /// 2026-07-13). En dessous, c'est un « presque » — un wave.
  static const certificateAfter = Duration(seconds: 10);

  /// Un seul wave par personne et par fenêtre. **Persisté** depuis le
  /// 2026-08-16 : en mémoire, redémarrer l'app suffisait à renotifier.
  static const waveCooldown = Duration(hours: 2);

  /// Croisements déjà certifiés dans cette session de présence, pour ne pas
  /// recommencer à chaque battement.
  final _certified = <String>{};

  @override
  Future<ProximityView> build() async {
    ref.onDispose(() {
      _radioFeed?.cancel();
      _peerFeed?.cancel();
      _certificates?.cancel();
      unawaited(_network?.dispose());
    });

    final runtime = ref.watch(proximitySupervisorProvider);
    await _ensureNetwork();

    return ProximityView(
      runtime: runtime,
      peers: _network?.presence.peers ?? const [],
      requests: await _journal.pendingRequests(),
    );
  }

  Future<void> _ensureNetwork() async {
    if (_network != null) return;
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;

    final supervisor = ref.read(proximitySupervisorProvider.notifier);
    final network = PeerNetwork(
      myUserId: me,
      myProfile: _mySnapshot,
      radio: _RadioAdapter(),
      identity: _identity,
      keyBook: _keyBook,
    );
    _network = network;
    await network.start();

    _radioFeed = supervisor.events.listen(network.onRadioEvent);
    _peerFeed = network.events.listen(_onPeerEvent);
    _certificates = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_sweepCertificates()),
    );
  }

  Future<PingPeerSnapshot> _mySnapshot() async {
    final me = ref.read(currentUserIdProvider)!;
    final profile = await ref.read(myProfileProvider.future);
    return PingPeerSnapshot(
      userId: me,
      username: profile?.displayName ?? 'inconnu',
      tagName: profile?.tagName,
      verified: true,
    );
  }

  // ------------------------------------------------------------------
  // Réactions
  // ------------------------------------------------------------------

  Future<void> _onPeerEvent(PeerEvent event) async {
    switch (event) {
      case PresenceChanged():
        _refresh();
      case PeerIdentified(:final snapshot, :final isFriend):
        if (isFriend) await _maybeWave(snapshot);
        _refresh();
      case PeerMessageReceived(:final address, :final snapshot, :final message):
        await _onMessage(address, snapshot, message);
      case PeerLost(:final peer):
        _certified.remove(peer.address);
        _refresh();
    }
  }

  Future<void> _onMessage(
    String address,
    PingPeerSnapshot peer,
    PeerMessage message,
  ) async {
    switch (message) {
      case ChatMessage(:final id, :final text, :final sentAt):
        await ref
            .read(pingStoreProvider)
            .append(
              peer.userId,
              peer: peer,
              message: PingMessage(id: id, mine: false, text: text, at: sentAt),
            );
        _refresh();

      case CertOfferMessage():
        await _counterSign(address, message);

      case CertFinalMessage(:final certificate):
        await _storeEncounter(peer, certificate);

      case FriendRequestMessage():
        await _onFriendRequest(peer, message);

      case FriendAcceptMessage():
        await _onFriendAccept(peer, message);

      case FriendDeclineMessage():
        // ⚠️ Un refus est une INFORMATION. Le taire laissait l'émetteur sur une
        // demande sans réponse, sans savoir si elle avait été vue ou perdue.
        await _journal.removeRequest(peer.userId);
        _refresh();

      case ProfileMessage():
        break; // traité par le réseau, qui vérifie les signatures.
    }
  }

  // ------------------------------------------------------------------
  // Certificats de croisement
  // ------------------------------------------------------------------

  /// Cherche les pairs présents depuis assez longtemps pour être certifiés.
  ///
  /// ⚠️ **Les AMIS en font partie, et c'est le correctif du défaut B1.** Avant,
  /// un ami reconnu à son ID rotatif sortait du traitement par un retour
  /// anticipé : aucune session n'était ouverte, donc **aucun certificat n'était
  /// jamais produit entre amis**. Or les streaks sont par définition entre amis
  /// — la fondation ne se remplissait pas pour le cas qu'elle doit servir.
  ///
  /// Décision de Jay (2026-08-16) : l'échange est **court**. On ouvre le lien —
  /// il n'y a pas d'autre moyen de faire signer quelqu'un — mais on n'échange
  /// aucun profil : on le connaît déjà par le carnet.
  Future<void> _sweepCertificates() async {
    final network = _network;
    if (network == null) return;
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;

    for (final peer in network.presence.peers) {
      final userId = peer.userId;
      if (userId == null || _certified.contains(peer.address)) continue;
      if (network.presence.contactDuration(peer.address) < certificateAfter) {
        continue;
      }
      // Un seul des deux propose, sinon on obtient deux certificats pour un
      // même croisement. L'ordre des identifiants tranche, et il est stable.
      if (me.compareTo(userId) >= 0) continue;

      _certified.add(peer.address);
      try {
        await network.ensureChannel(peer.address);
        final ts = DateTime.now().toUtc().toIso8601String();
        await network.send(
          peer.address,
          CertOfferMessage(
            a: me,
            b: userId,
            timestamp: ts,
            signatureA: await _identity.sign(
              CertOfferMessage.signedPayload(me, userId, ts),
            ),
            devicePublicKeyA: await _identity.edPublicKey(),
          ),
        );
      } catch (_) {
        // Le pair est reparti ou le lien a échoué : on réessaiera au prochain
        // croisement. On retire le verrou pour que ce soit possible.
        _certified.remove(peer.address);
      }
    }
  }

  Future<void> _counterSign(String address, CertOfferMessage offer) async {
    final me = ref.read(currentUserIdProvider);
    final network = _network;
    if (me == null || network == null) return;
    if (offer.b != me) return;

    final payload = CertOfferMessage.signedPayload(
      offer.a,
      offer.b,
      offer.timestamp,
    );
    final ok = await ProximityIdentity.verify(
      payload,
      offer.signatureA,
      offer.devicePublicKeyA,
    );
    if (!ok) return;

    final certificate = {
      'a': offer.a,
      'b': offer.b,
      'ts': offer.timestamp,
      'sigA': base64Encode(offer.signatureA),
      'sigB': base64Encode(await _identity.sign(payload)),
      'edPubA': base64Encode(offer.devicePublicKeyA),
      'edPubB': base64Encode(await _identity.edPublicKey()),
    };
    await network.send(address, CertFinalMessage(certificate));
    _certified.add(address);

    final peer = network.presence.byAddress(address)?.snapshot;
    if (peer != null) await _storeEncounter(peer, certificate);
  }

  Future<void> _storeEncounter(
    PingPeerSnapshot peer,
    Map<String, dynamic> certificate,
  ) async {
    final store = ref.read(pingStoreProvider);
    await store.addEncounter(
      LocalEncounter(peer: peer, at: DateTime.now(), certificate: certificate),
    );
    await store.enqueue({'type': 'encounter', 'certificate': certificate});
    _refresh();
  }

  // ------------------------------------------------------------------
  // Demandes d'amis
  // ------------------------------------------------------------------

  /// Envoie une demande d'ami à un pair présent.
  ///
  /// Lève si le pair n'est plus joignable — **l'appelant doit le dire à
  /// l'utilisateur**. Un envoi qui échoue en silence est ce qui faisait
  /// disparaître des demandes sans que personne ne le sache.
  Future<void> requestFriendship(String userId) async {
    final network = _network;
    final me = ref.read(currentUserIdProvider);
    if (network == null || me == null) throw StateError('proximité inactive');

    final ts = DateTime.now().toUtc().toIso8601String();
    await network.sendToUser(
      userId,
      FriendRequestMessage(
        from: me,
        to: userId,
        timestamp: ts,
        signature: await _identity.sign(
          FriendRequestMessage.signedPayload(me, userId, ts),
        ),
        devicePublicKey: await _identity.edPublicKey(),
        broadcastKey: await _identity.broadcastKey(),
      ),
    );
  }

  Future<void> _onFriendRequest(
    PingPeerSnapshot peer,
    FriendRequestMessage request,
  ) async {
    final me = ref.read(currentUserIdProvider);
    if (me == null || request.to != me || request.from != peer.userId) return;

    final ok = await ProximityIdentity.verify(
      FriendRequestMessage.signedPayload(
        request.from,
        request.to,
        request.timestamp,
      ),
      request.signature,
      request.devicePublicKey,
    );
    if (!ok) return;

    // Persistée : elle survit à la fermeture de l'app et à l'éloignement.
    await _journal.putRequest(
      PendingFriendRequest(
        fromUserId: request.from,
        snapshot: peer,
        payload: request.toJson(),
        receivedAt: DateTime.now(),
      ),
    );
    _refresh();
  }

  /// Répond à une demande.
  ///
  /// ⚠️ **La demande n'est retirée qu'APRÈS le succès.** L'ancienne version
  /// effaçait la bannière en premier, puis abandonnait en silence si le lien
  /// était tombé : la demande était perdue pour toujours, sans copie serveur, et
  /// l'émetteur n'apprenait jamais rien (défaut A3).
  Future<void> respondToRequest(
    String fromUserId, {
    required bool accept,
  }) async {
    final network = _network;
    final me = ref.read(currentUserIdProvider);
    if (network == null || me == null) throw StateError('proximité inactive');

    final pending = (await _journal.pendingRequests()).firstWhere(
      (r) => r.fromUserId == fromUserId,
      orElse: () => throw StateError('demande introuvable'),
    );

    if (!accept) {
      // On tente de prévenir, mais un refus reste un refus même si le pair est
      // déjà parti : la demande disparaît de chez nous dans tous les cas.
      try {
        await network.sendToUser(fromUserId, const FriendDeclineMessage());
      } catch (_) {}
      await _journal.removeRequest(fromUserId);
      _refresh();
      return;
    }

    final request = FriendRequestMessage.fromJson(pending.payload);
    final record = {
      ...request.record,
      'sigTo': base64Encode(
        await _identity.sign(
          FriendAcceptMessage.signedPayload(
            request.from,
            request.to,
            request.timestamp,
          ),
        ),
      ),
    };

    // Si ceci lève, la demande RESTE : l'utilisateur pourra réessayer quand la
    // personne sera de nouveau à portée.
    await network.sendToUser(
      fromUserId,
      FriendAcceptMessage(
        record: record,
        devicePublicKey: await _identity.edPublicKey(),
        broadcastKey: await _identity.broadcastKey(),
      ),
    );

    await _keyBook.put(
      FriendKeys(
        userId: request.from,
        username: pending.snapshot.username,
        tagName: pending.snapshot.tagName,
        edPublicKey: request.devicePublicKey,
        broadcastKey: request.broadcastKey,
      ),
    );
    await network.refreshFriends();
    await ref.read(pingStoreProvider).enqueue({
      'type': 'connection',
      'record': record,
    });
    await _journal.removeRequest(fromUserId);
    _refresh();
  }

  Future<void> _onFriendAccept(
    PingPeerSnapshot peer,
    FriendAcceptMessage accept,
  ) async {
    final network = _network;
    if (network == null) return;
    await _keyBook.put(
      FriendKeys(
        userId: peer.userId,
        username: peer.username,
        tagName: peer.tagName,
        edPublicKey: accept.devicePublicKey,
        broadcastKey: accept.broadcastKey,
      ),
    );
    await network.refreshFriends();
    await ref.read(pingStoreProvider).enqueue({
      'type': 'connection',
      'record': accept.record,
    });
    _refresh();
  }

  // ------------------------------------------------------------------
  // Chat et waves
  // ------------------------------------------------------------------

  Future<void> sendMessage(String userId, String text) async {
    final network = _network;
    if (network == null) throw StateError('proximité inactive');
    final peer = network.presence.byUser(userId);
    if (peer?.snapshot == null) throw StateError('pair hors de portée');

    final now = DateTime.now();
    final id = _randomId();
    await network.sendToUser(
      userId,
      ChatMessage(id: id, text: text, sentAt: now),
    );
    // ⚠️ Rangé APRÈS l'envoi, jamais avant : si l'envoi échoue, le message ne
    // doit pas apparaître comme parti. Un message affiché mais jamais transmis
    // est le pire des deux mondes — l'utilisateur croit avoir parlé.
    await ref
        .read(pingStoreProvider)
        .append(
          userId,
          peer: peer!.snapshot!,
          message: PingMessage(id: id, mine: true, text: text, at: now),
        );
    _refresh();
  }

  Future<void> _maybeWave(PingPeerSnapshot friend) async {
    if (!await _journal.mayWave(friend.userId, waveCooldown)) return;
    await _journal.noteWave(friend.userId);

    final profile = await ref.read(myProfileProvider.future);
    final realtime = profile?.realtimeWaves ?? false;
    final when = realtime
        ? DateTime.now()
        : DateTime.now().add(const Duration(minutes: 45));
    await NotificationService.instance.schedule(
      NotifChannel.waves,
      'Le presque…',
      '${friend.username} est passé tout près de toi.',
      when,
    );
    await ref.read(pingStoreProvider).enqueue({
      'type': 'wave',
      'peerId': friend.userId,
      'notifyAfter': when.toUtc().toIso8601String(),
    });
  }

  // ------------------------------------------------------------------

  void _refresh() {
    final network = _network;
    if (network == null) return;
    final runtime = ref.read(proximitySupervisorProvider);
    unawaited(
      _journal.pendingRequests().then((requests) {
        state = AsyncData(
          ProximityView(
            runtime: runtime,
            peers: network.presence.peers,
            requests: requests,
          ),
        );
      }),
    );
  }

  static String _randomId() {
    final rnd = Random.secure();
    return List.generate(
      8,
      (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

/// Traduit les ordres du réseau vers la radio native.
///
/// Existe pour que `PeerNetwork` ne dépende que d'une interface étroite — c'est
/// ce qui permet de le faire tourner en test avec deux radios simulées.
class _RadioAdapter implements RadioCommands {
  final _radio = BleRadio();

  @override
  Future<int> connect(String address) => _radio.connect(address);

  @override
  void disconnect(String linkId) => unawaited(_radio.disconnect(linkId));

  @override
  Future<void> send(String linkId, Uint8List chunk) =>
      _radio.send(linkId, chunk);
}

final proximityControllerProvider =
    AsyncNotifierProvider<ProximityController, ProximityView>(
      ProximityController.new,
    );
