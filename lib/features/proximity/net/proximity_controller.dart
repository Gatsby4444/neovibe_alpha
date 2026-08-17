import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../proximity_identity.dart';
import 'connection_trace.dart';
import 'peer_network.dart';
import 'presence_tracker.dart';
import 'proximity_journal.dart';
import 'proximity_protocol.dart';
import 'ble_radio.dart';
import 'proximity_supervisor.dart';
import 'proximity_sync.dart';
import 'radio_status.dart';

/// Pourquoi une demande d'ami n'est pas partie.
///
/// ⚠️ **Un motif nommé, pas une exception générique.** L'interface attrapait
/// tout dans un `catch (_)` et affichait « rapproche-toi et réessaie » — un
/// conseil **faux** quand la vraie raison était « vous êtes déjà connectés » ou
/// « c'est déjà envoyé ». Une réponse fausse est pire qu'une absence de
/// réponse : elle envoie l'utilisateur faire quelque chose d'inutile.
class FriendRequestRefused implements Exception {
  const FriendRequestRefused.alreadyFriends()
    : message = 'Vous êtes déjà connectés.';
  const FriendRequestRefused.alreadySent()
    : message = 'Demande déjà envoyée — en attente de sa réponse.';

  final String message;

  @override
  String toString() => message;
}

/// Ce que l'interface a besoin de savoir, et rien de plus.
class ProximityView {
  const ProximityView({
    this.peers = const [],
    this.requests = const [],
    this.outgoing = const [],
  });

  /// Qui est autour, avec son état d'identification.
  final List<PresencePeer> peers;

  /// Demandes d'amis en attente — **plusieurs**, et **persistantes**.
  final List<PendingFriendRequest> requests;

  /// Les demandes que **nous** avons envoyées, et où elles en sont.
  ///
  /// ⚠️ Sans elles, l'interface ne pouvait rien dire : elle réaffichait le
  /// bouton « demander » après un envoi réussi, et répondait « Demande
  /// envoyée » à chaque clic. Une action doit aboutir à un état visible.
  final List<OutgoingFriendRequest> outgoing;

  /// Notre demande vers cette personne, si elle existe.
  OutgoingFriendRequest? outgoingTo(String userId) {
    for (final r in outgoing) {
      if (r.toUserId == userId) return r;
    }
    return null;
  }

  List<PresencePeer> get identified =>
      peers.where((p) => p.stage == PresenceStage.identified).toList();
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

  /// ⚠️ **Le carnet vient du provider, il ne se construit pas ici.**
  ///
  /// Ce champ valait `FriendKeyBook()`. La synchronisation en avait un autre, et
  /// `PeerNetwork` un troisième par défaut — trois caches mémoire sur un seul
  /// fichier. Les clés téléchargées n'arrivaient jamais jusqu'ici.
  FriendKeyStore get _keyBook => ref.read(friendBookProvider);

  /// Croisement VALIDÉ = contact continu pendant ce délai (décision de Jay,
  /// 2026-07-13). En dessous, c'est un « presque » — un wave.
  static const certificateAfter = Duration(seconds: 10);

  /// Un seul wave par personne et par fenêtre. **Persisté** depuis le
  /// 2026-08-16 : en mémoire, redémarrer l'app suffisait à renotifier.
  static const waveCooldown = Duration(hours: 2);

  /// Croisements déjà certifiés dans cette session de présence, pour ne pas
  /// recommencer à chaque battement.
  final _certified = <String>{};

  /// Le compte auquel le local du ping appartient actuellement.
  String? _boundUserId;

  @override
  Future<ProximityView> build() async {
    // ⚠️ **On ne surveille QUE le compte.**
    //
    // Ce `build` surveillait l'état de la radio (`ref.watch` du superviseur).
    // Or Riverpod ré-exécute `build` à chaque changement de ce qu'il surveille,
    // **et déclenche d'abord les `onDispose` de l'exécution précédente**. Chaque
    // transition d'état — et il y en a au moins deux à chaque démarrage,
    // `starting` puis `running` — **détruisait donc le réseau de pairs**
    // aussitôt créé. Le champ `_network`, lui, restait non nul : `_ensureNetwork`
    // repartait immédiatement, satisfait, en laissant l'app branchée sur un
    // objet mort. Plus aucun scan, plus aucun événement, pour toujours.
    //
    // Le défaut était invisible : rien ne plante, rien ne s'affiche. C'est la
    // deuxième moitié de ce que Jay a constaté au test de la v0.9.98.
    //
    // La règle qui en sort : **une référence qui pointe vers un objet détruit
    // doit être remise à nul dans le même geste**. Un champ non nul vers un
    // cadavre est un nœud orphelin — il ment à tous ceux qui le consultent.
    final me = ref.watch(currentUserIdProvider);
    ref.onDispose(_teardown);

    // ⚠️ **Changement de compte : on efface le local du ping.**
    //
    // Rien ne le faisait — `signOut()` ne nettoyait que la session serveur.
    // Or le carnet de clés, les conversations ping, les croisements et les
    // demandes en attente sont des fichiers **sans propriétaire inscrit** : un
    // compte B ouvert sur le même appareil héritait de tout, et reconnaissait
    // **silencieusement** les amis du compte A grâce à leurs clés de diffusion.
    //
    // Pour une app dont la thèse est le cercle restreint, c'est une fuite. Les
    // méthodes d'effacement existaient déjà côté magasins ; **personne ne les
    // appelait** — un nœud orphelin, au sens exact du terme.
    if (_boundUserId != null && _boundUserId != me) await _forgetLocalPing();
    _boundUserId = me;

    if (me != null) await _ensureNetwork(me);

    return ProximityView(
      peers: _network?.presence.peers ?? const [],
      requests: await _journal.pendingRequests(),
      outgoing: await _journal.outgoingRequests(),
    );
  }

  /// Défait tout, **et remet les références à nul**.
  void _teardown() {
    _radioFeed?.cancel();
    _radioFeed = null;
    _peerFeed?.cancel();
    _peerFeed = null;
    _certificates?.cancel();
    _certificates = null;
    final network = _network;
    _network = null; // ← la ligne qui manquait
    unawaited(network?.dispose());
  }

  /// Efface tout ce que le ping garde en local, pour le compte qui s'en va.
  Future<void> _forgetLocalPing() async {
    _certified.clear();
    await _journal.clear();
    await _keyBook.clear();
    await ref.read(pingStoreProvider).wipe();
  }

  Future<void> _ensureNetwork(String me) async {
    if (_network != null) return;

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

    // ⚠️ Le balayage des conversations expirées (TTL 12 h) était appelé par
    // l'ancien `enable()`. Sa suppression l'a laissé **sans aucun appelant** :
    // les messages ping ne se seraient plus jamais purgés, alors que leur
    // effacement est une promesse du produit, pas une optimisation.
    unawaited(ref.read(pingStoreProvider).sweep());

    // La synchro part au démarrage : c'est le moment où l'on récupère les clés
    // des amis, sans lesquelles aucune reconnaissance silencieuse n'est
    // possible.
    unawaited(ref.read(proximitySyncProvider).run());

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
      case PeerIdentified(:final snapshot):
        // Le réseau dit QUI ; c'est ici, au-dessus de la frontière, qu'on sait
        // ce que cette personne est pour nous.
        if (await _isFriend(snapshot.userId)) await _maybeWave(snapshot);
        _refresh();
      case PeerMessageReceived(:final address, :final snapshot, :final message):
        await _onMessage(address, snapshot, message);
      case PeerLost(:final peer):
        _certified.remove(peer.address);
        _refresh();
    }
  }

  /// Pairs qui ont refusé notre dernier message (règle anti-spam).
  ///
  /// Vidé dès qu'ils nous écrivent : leur message EST la réponse attendue.
  final _rejections = <String>{};

  /// Vrai si [userId] a refusé notre dernier message.
  bool wasRejectedBy(String userId) => _rejections.contains(userId);

  Future<void> _onMessage(
    String address,
    PingPeerSnapshot peer,
    PeerMessage message,
  ) async {
    final network = _network;
    if (network == null) return;
    switch (message) {
      case ChatMessage(:final id, :final text, :final sentAt):
        final isFriend = await _isFriend(peer.userId);
        final accepted = await ref
            .read(pingStoreProvider)
            .append(
              peer.userId,
              peer: peer,
              message: PingMessage(id: id, mine: false, text: text, at: sentAt),
              fromFriend: isFriend,
            );
        if (!accepted) {
          // ⚠️ **On le DIT à l'émetteur.** Refuser un message est une décision
          // défendable ; le détruire sans que personne ne le sache ne l'est
          // pas. Sans cette réponse, l'émetteur voit son message parti et le
          // destinataire ne voit rien — un silence que rien ne permet
          // d'expliquer, des deux côtés.
          try {
            await network.send(address, const ChatRejectedMessage());
          } catch (_) {
            // Le lien est tombé : l'émetteur le saura autrement.
          }
        }
        _refresh();

      case ChatRejectedMessage():
        // Notre message a été refusé par la règle anti-spam d'en face.
        _rejections.add(peer.userId);
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
        // ⚠️ **Un refus répond à une demande SORTANTE.**
        //
        // Cette ligne appelait `removeRequest`, qui retire une demande
        // **entrante** : le mauvais magasin. Celui qui avait demandé
        // n'apprenait donc jamais qu'on lui avait dit non — et si le pair lui
        // avait *aussi* écrit, c'est sa demande à lui qui disparaissait.
        //
        // Le commentaire d'origine affirmait exactement le contraire de ce que
        // le code faisait.
        final connue = await _journal.markOutgoingDeclined(peer.userId);
        if (!connue) {
          // Un refus sans demande de notre part : on le consigne au lieu de
          // l'avaler.
          ConnectionTrace.note(
            ConnectionEvent.declineWithoutRequest,
            subject: peer.userId,
          );
        }
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
    unawaited(ref.read(proximitySyncProvider).run());
    _refresh();
  }

  // ------------------------------------------------------------------
  // Demandes d'amis
  // ------------------------------------------------------------------

  /// Suis-je ami avec cette personne ? **Une seule source, le carnet.**
  Future<bool> _isFriend(String userId) async =>
      (await _keyBook.all()).containsKey(userId);

  /// Envoie une demande d'ami à un pair présent.
  ///
  /// Lève si le pair n'est plus joignable — **l'appelant doit le dire à
  /// l'utilisateur**. Un envoi qui échoue en silence est ce qui faisait
  /// disparaître des demandes sans que personne ne le sache.
  Future<void> requestFriendship(String userId) async {
    final network = _network;
    final me = ref.read(currentUserIdProvider);
    if (network == null || me == null) throw StateError('proximité inactive');

    // ⚠️ **Ceinture, pas bretelles.** Le bouton ne s'affiche plus pour un ami
    // (le statut se dérive du carnet), donc ce cas ne devrait pas se produire.
    // Il reste possible sur une course : deux personnes qui se demandent en
    // même temps, ou une interface pas encore redessinée. Le dire vaut mieux
    // que d'envoyer une demande qui n'a pas de sens.
    if (await _isFriend(userId)) {
      ConnectionTrace.note(ConnectionEvent.requestToFriend, subject: userId);
      throw const FriendRequestRefused.alreadyFriends();
    }

    // ⚠️ **Une demande déjà partie ne se renvoie pas en boucle.** Jay a cliqué
    // plusieurs fois et lu « Demande envoyée » à chaque fois : l'app n'avait
    // aucune mémoire de ce qu'elle venait de faire.
    final deja = await _journal.outgoingTo(userId);
    if (deja != null && !deja.isDeclined) {
      throw const FriendRequestRefused.alreadySent();
    }

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
    // ⚠️ **Rangée APRÈS l'envoi, jamais avant.** `sendToUser` lève si le pair
    // n'est plus joignable : une demande qui n'est pas partie ne doit pas
    // s'afficher comme envoyée. C'est la même règle que pour les messages.
    final peer = network.presence.byUser(userId)?.snapshot;
    if (peer != null) {
      await _journal.putOutgoing(
        OutgoingFriendRequest(
          toUserId: userId,
          snapshot: peer,
          sentAt: DateTime.now(),
        ),
      );
    }
    ConnectionTrace.count(ConnectionTrace.requestsSent);
    _refresh();
  }

  Future<void> _onFriendRequest(
    PingPeerSnapshot peer,
    FriendRequestMessage request,
  ) async {
    final me = ref.read(currentUserIdProvider);
    if (me == null || request.to != me || request.from != peer.userId) {
      ConnectionTrace.note(
        ConnectionEvent.notForUs,
        subject: request.from,
        detail: 'destinataire ${request.to}',
      );
      return;
    }

    final ok = await ProximityIdentity.verify(
      FriendRequestMessage.signedPayload(
        request.from,
        request.to,
        request.timestamp,
      ),
      request.signature,
      request.devicePublicKey,
    );
    if (!ok) {
      ConnectionTrace.note(ConnectionEvent.badSignature, subject: request.from);
      return;
    }

    // ⚠️ **Déjà amis : rien à demander.** Sans cette garde, une demande
    // redondante créait un encadré « X veut se connecter avec toi » entre deux
    // personnes déjà connectées — ce que Jay a vu le 2026-08-17.
    if (await _isFriend(request.from)) {
      ConnectionTrace.note(
        ConnectionEvent.requestFromFriend,
        subject: request.from,
      );
      return;
    }

    ConnectionTrace.count(ConnectionTrace.requestsReceived);

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
      ConnectionTrace.count(ConnectionTrace.declined);
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
    unawaited(ref.read(proximitySyncProvider).run());
    await _journal.removeRequest(fromUserId);
    ConnectionTrace.count(ConnectionTrace.accepted);
    _refresh();
  }

  /// ⚠️ **Une acceptation d'ami ne se croit pas sur parole.**
  ///
  /// Cette méthode ne vérifiait **rien** : elle rangeait l'émetteur dans le
  /// carnet d'amis sur la seule foi du message. Or n'importe quel pair ayant
  /// abouti la poignée de main — donc n'importe qui de physiquement à côté —
  /// pouvait envoyer une `FriendAcceptMessage` que nous n'avions jamais
  /// demandée, et **s'inscrire lui-même dans notre carnet**.
  ///
  /// Conséquences locales, immédiates : il s'affichait comme ami, la règle
  /// anti-spam cessait de s'appliquer à lui, et il devenait reconnaissable en
  /// silence à son identifiant rotatif. Le serveur, lui, aurait refusé la
  /// connexion — mais le carnet local ne l'apprend qu'à la synchro suivante,
  /// donc jamais tant qu'on est hors ligne.
  ///
  /// **Pour une app dont toute la thèse est qu'être à côté ne suffit pas à être
  /// ami, c'est la barrière fondatrice qui tombait.**
  ///
  /// La vérification décisive tient en une ligne et ne demande aucun état
  /// nouveau : **le record porte NOTRE propre signature.** On la vérifie avec
  /// notre clé d'appareil. Un tiers ne peut pas la fabriquer, donc il ne peut
  /// pas fabriquer une acceptation d'une demande que nous n'avons pas faite.
  /// C'est exactement ce que fait le serveur dans `submit_ble_connection` ;
  /// nous ne le faisions simplement pas de notre côté.
  Future<void> _onFriendAccept(
    PingPeerSnapshot peer,
    FriendAcceptMessage accept,
  ) async {
    final network = _network;
    final me = ref.read(currentUserIdProvider);
    if (network == null || me == null) return;

    final refus = await accept.refusalFor(
      me: me,
      peerUserId: peer.userId,
      myDeviceKey: await _identity.edPublicKey(),
    );
    if (refus != null) {
      ConnectionTrace.note(
        ConnectionEvent.acceptNotOurs,
        subject: peer.userId,
        detail: refus,
      );
      return;
    }

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
    // La demande a abouti : son état final est « on est amis », et le carnet
    // le dit. L'entrée sortante n'a plus lieu d'être.
    await _journal.removeOutgoing(peer.userId);
    await ref.read(pingStoreProvider).enqueue({
      'type': 'connection',
      'record': accept.record,
    });
    unawaited(ref.read(proximitySyncProvider).run());
    _refresh();
  }

  /// Oublie une demande sortante refusée — geste explicite de l'utilisateur.
  Future<void> dismissOutgoing(String userId) async {
    await _journal.removeOutgoing(userId);
    _refresh();
  }

  // ------------------------------------------------------------------
  // Chat et waves
  // ------------------------------------------------------------------

  Future<void> sendMessage(String userId, String text) async {
    // Notre interlocuteur nous parle de nouveau : le refus est levé.
    _rejections.remove(userId);
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
    unawaited(ref.read(proximitySyncProvider).run());
  }

  // ------------------------------------------------------------------

  void _refresh() {
    final network = _network;
    if (network == null) return;
    unawaited(() async {
      final requests = await _journal.pendingRequests();
      final outgoing = await _journal.outgoingRequests();
      state = AsyncData(
        ProximityView(
          peers: network.presence.peers,
          requests: requests,
          outgoing: outgoing,
        ),
      );
    }());
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

/// Vrai si [userId] est à portée **maintenant**.
///
/// Point d'entrée unique pour tout ce qui exige la présence physique — la
/// barrière fondatrice du produit. Il ne doit jamais s'appuyer sur un souvenir :
/// c'est la présence vivante qui répond, pas un historique.
final peerInRangeProvider = Provider.family<bool, String>((ref, userId) {
  final view = ref.watch(proximityControllerProvider).value;
  return view?.identified.any((p) => p.userId == userId) ?? false;
});

final proximityControllerProvider =
    AsyncNotifierProvider<ProximityController, ProximityView>(
      ProximityController.new,
    );
