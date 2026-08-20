import 'dart:async';
import 'dart:typed_data';

import '../ping_store.dart';
import '../proximity_identity.dart';
import 'advert_plan.dart';
import 'peer_link.dart';
import 'peer_session.dart';
import 'proximity_protocol.dart';
import 'radio_status.dart';
import 'secure_channel.dart';
import 'transport_trace.dart';

/// Ce que le réseau constate, une fois les octets devenus du sens.
///
/// C'est la frontière : en dessous, on parle radio, trames et clés ; au-dessus,
/// on parle profils, messages et certificats. **Aucune fonction produit ne
/// descend sous cette ligne.**
sealed class PeerEvent {
  const PeerEvent();
}

/// La présence a changé — quelqu'un est arrivé, parti, ou vient d'être
/// identifié. L'interface se redessine là-dessus, et sur rien d'autre.
class PresenceChanged extends PeerEvent {
  const PresenceChanged();
}

/// Un pair s'est révélé : on sait maintenant QUI il est.
///
/// ⚠️ Il n'y a pas de `isFriend` ici, et c'est délibéré : le réseau dit **qui**,
/// jamais **ce que cette personne est pour moi** — cette question-là se pose au
/// carnet, au moment du rendu.
class PeerIdentified extends PeerEvent {
  const PeerIdentified(this.address, this.snapshot);
  final String address;
  final PingPeerSnapshot snapshot;
}

/// Un message applicatif est arrivé, déchiffré et authentifié.
class PeerMessageReceived extends PeerEvent {
  const PeerMessageReceived(this.address, this.snapshot, this.message);
  final String address;
  final PingPeerSnapshot snapshot;
  final PeerMessage message;
}

/// Un pair a quitté la portée.
class PeerLost extends PeerEvent {
  const PeerLost(this.peer);
  final PresencePeer peer;
}

/// Le réseau de pairs : liens, canaux, présence.
///
/// ## Ce qu'il fait
///
/// Il transforme un flux d'événements radio en un flux d'événements de pairs :
/// il ouvre les liens, tient un canal chiffré par pair, réassemble les trames,
/// vérifie les identités, et publie ce qui a du sens.
///
/// ## Ce qu'il ne fait pas
///
/// Il ne sait pas ce qu'est un certificat de croisement, un wave ou une demande
/// d'ami. Il transporte des [PeerMessage] ; ce sont les fonctions, au-dessus,
/// qui décident quoi en faire.
///
/// ## ⚠️ Ce qui a changé le 2026-08-18
///
/// Ce fichier tenait **neuf collections indexées par adresse** — présence,
/// liens, canaux, identités, connexions en cours, replis armés, profils envoyés,
/// croisements certifiés — qu'il fallait nettoyer ensemble, à la main, à chaque
/// sortie. Tous les défauts du chantier sont le même : *la collection X a été
/// nettoyée, la Y non*. Au point que la boucle de nettoyage des adresses
/// fusionnées existait **en deux exemplaires**, dont les corps avaient déjà
/// divergé.
///
/// Il n'y a plus qu'un [PeerRegistry] de [PeerSession]. Fermer un pair est
/// **un geste** ([_close]), et il n'existe aucun autre chemin pour le faire.
class PeerNetwork {
  PeerNetwork({
    required this.myUserId,
    required this.myProfile,
    required this.radio,
    required FriendKeyStore keyBook,
    required ProximityIdentity identity,
    DateTime Function()? clock,
    // Les champs sont privés : un paramètre formel initialisant les exposerait
    // sous leur nom privé, que les appelants ne peuvent pas nommer.
    // ignore: prefer_initializing_formals
  }) : _keyBook = keyBook,
       // ignore: prefer_initializing_formals
       _identity = identity,
       _clock = clock ?? DateTime.now {
    presence = PeerRegistry(clock: clock);
  }

  /// Mon identifiant. Sert à décider qui initie et à signer.
  final String myUserId;

  /// Mon mini-profil, envoyé dans le tunnel chiffré.
  final Future<PingPeerSnapshot> Function() myProfile;

  final RadioCommands radio;
  final ProximityIdentity _identity;
  final FriendKeyStore _keyBook;
  final DateTime Function() _clock;

  /// **L'heure de la proximité.** Une seule autorité pour toute la
  /// fonctionnalité : le registre expire les sessions contre cette horloge, et
  /// tout ce qui juge une session doit la lire ici.
  ///
  /// ⚠️ Le balayage des certificats appelait `DateTime.now()` directement
  /// (audit du 2026-08-18, point G). Sans effet en production — les deux
  /// valaient la même chose — mais sous horloge simulée, le registre et le
  /// balayage n'étaient plus au même instant, et ce chemin devenait intestable.
  DateTime now() => _clock();

  /// Le registre des pairs. Nommé `presence` parce que c'est la question qu'on
  /// lui pose ; il possède aussi le transport, qui n'intéresse que ce fichier.
  late final PeerRegistry presence;

  /// Au bout de ce délai, le côté passif prend l'initiative.
  ///
  /// L'initiateur est choisi par comparaison des identifiants diffusés, donc
  /// exactement un des deux ouvre. Mais si celui-là n'y arrive pas — écran
  /// éteint, pile GATT occupée — la paire ne se rencontrerait **jamais**.
  static const passiveFallback = Duration(seconds: 12);

  /// Au-delà, on considère que le lien ne s'ouvrira pas.
  static const connectTimeout = Duration(seconds: 15);

  /// Table jeton reçu → ami, reconstruite à chaque créneau.
  ///
  /// ⚠️ **Elle ne contient plus de clés, seulement des jetons attendus.** Le
  /// carnet range des clés publiques ; `AdvertPlanner` en dérive ce qu'on
  /// s'attend à recevoir. Le réseau, lui, ne fait que comparer.
  RecognitionTable _recognition = const RecognitionTable(
    fromSlot: 0,
    toSlot: -1,
    byToken: {},
  );
  Map<String, FriendKeys> _friends = {};
  int _slot = -1;

  static const _planner = AdvertPlanner();

  final _events = StreamController<PeerEvent>.broadcast();
  Stream<PeerEvent> get events => _events.stream;

  Timer? _housekeeping;

  Future<void> start() async {
    // On s'abonne au carnet, on ne le relit pas à heure fixe : peu importe qui
    // arrive en premier, du réseau ou des clés téléchargées.
    _keyBook.changes.addListener(_onBookChanged);
    await refreshFriends();
    _housekeeping ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(tick()),
    );
  }

  void _onBookChanged() => unawaited(refreshFriends());

  /// ⚠️ **Fermer le réseau doit COUPER LA RADIO, pas seulement oublier.**
  ///
  /// Cette méthode se contentait de `session.release()` : le Dart oubliait, le
  /// natif gardait ses liens GATT. C'est exactement le piège que le transport
  /// documente ailleurs — `connect()` rend un succès **immédiat et sans le
  /// moindre événement** quand un lien existe déjà. Le `PeerNetwork` suivant
  /// attendait donc un événement qui ne viendrait jamais, et ce pair devenait
  /// injoignable pour toute la vie du service, sans erreur ni trace.
  ///
  /// Elle passe donc par [_closeTransport], comme les deux autres chemins de
  /// fermeture (`_close` et la branche « la radio s'est arrêtée » de
  /// [onRadioEvent]). Trois chemins, une seule règle.
  ///
  /// Relevé à l'audit du 2026-08-18 (point B), corrigé le 2026-08-20.
  Future<void> dispose() async {
    _keyBook.changes.removeListener(_onBookChanged);
    _housekeeping?.cancel();
    _housekeeping = null;
    for (final session in presence.drain()) {
      _closeTransport(session);
    }
    await _events.close();
  }

  /// Y a-t-il un canal capable de chiffrer avec cette adresse ?
  ///
  /// ⚠️ **Point d'observation de test : aucun appelant dans `lib/`.** Vérifié à
  /// l'audit du 2026-08-18 (point E). Conservé délibérément — il permet aux
  /// tests de transport d'affirmer l'état du canal sans ouvrir la session — mais
  /// **à retirer avant la mise en production** avec les autres accès de test
  /// (`RAPPELS.md`). Ne pas l'appeler depuis du code de production : ce serait
  /// lire l'état du transport depuis une couche qui n'a pas à le connaître.
  bool hasEstablishedChannel(String address) =>
      presence.byAddress(address)?.hasChannel ?? false;

  /// Recharge le carnet d'amis et la table de reconnaissance du créneau.
  ///
  /// ⚠️ **Le coût est ici, et il est borné.** Un X25519 par ami (mis en cache
  /// par l'identité), puis trois HMAC par ami. Ce qui coûtait le double avant —
  /// la clé « précédente » doublait l'indexation sans changer aucun résultat.
  Future<void> refreshFriends() async {
    _slot = ProximityIdentity.slotIndex(_clock());
    _friends = await _keyBook.all();
    final secrets = await _identity.pairSecrets({
      for (final f in _friends.values) f.userId: f.x25519PublicKey,
    });
    _recognition = await _planner.table(secrets: secrets, slot: _slot);
  }

  // ------------------------------------------------------------------
  // Entrée : les constats de la radio
  // ------------------------------------------------------------------

  Future<void> onRadioEvent(RadioEvent event) async {
    switch (event) {
      case RadioStatusEvent(:final status):
        // La radio s'arrête : la présence n'est plus qu'un souvenir, et un
        // souvenir présenté comme une observation est exactement ce qu'on
        // supprime partout ici.
        if (!status.isDetecting && presence.length > 0) {
          for (final session in presence.drain()) {
            session.release();
            for (final a in session.addresses) {
              radio.disconnect(a);
            }
          }
          _publish();
        }
      case RadioScan(
        :final address,
        :final advertId,
        :final rssi,
        :final txPower,
      ):
        await _onScan(address, advertId, rssi, txPower);
      case RadioLink(
        :final linkId,
        :final connected,
        :final mtu,
        :final incoming,
      ):
        connected
            ? await _onLinkUp(linkId, mtu, incoming)
            : _onLinkDown(linkId);
      case RadioFrame(:final linkId, :final data):
        final session = presence.byAddress(linkId);
        final link = session?.link;
        if (session == null || link == null) {
          // Arrive normalement : les deux côtés s'ouvrent, et l'un peut parler
          // avant que notre événement de lien ne soit remonté. Si ce compteur
          // s'envole, c'est que des liens montent sans être vus.
          TransportTrace.drop(DropKind.noLink, linkId, '${data.length} octets');
          return;
        }
        // ⚠️ **Une trame reçue EST une preuve de présence.** C'est ce qui rend
        // tenable une fraîcheur de 5 s sans second délai de grâce.
        session.noteTraffic(_clock());
        link.receive(data);
    }
  }

  Future<void> _onScan(
    String address,
    Uint8List advertId,
    int rssi,
    int txPower,
  ) async {
    final hex = FriendKeyBook.hex(advertId);
    final friend = _friends[_recognition.match(advertId)];

    var session = presence.observe(address, rssi, txPower: txPower);

    // Un ami est reconnu ICI, sans poignée de main : c'est tout l'intérêt de
    // l'ID rotatif.
    if (friend != null && session.snapshot == null) {
      final result = presence.identify(
        session,
        PingPeerSnapshot(
          userId: friend.userId,
          username: friend.username,
          tagName: friend.tagName,
          verified: true,
        ),
      );
      if (result.merged != null) _closeTransport(result.merged!);
      session = result.session;
      _emit(PeerIdentified(session.address, session.snapshot!));
    }

    _publish();

    // Un ami reconnu n'a PAS besoin d'un lien pour être affiché. Il en faudra
    // un pour le certificat de croisement — c'est `tick` qui le décidera.
    if (session.snapshot != null) return;

    await _maybeOpenLink(session, hex);
  }

  /// Décide s'il faut ouvrir un lien vers un inconnu, et qui l'ouvre.
  ///
  /// ## ⚠️ On n'ouvre pas au premier signe de vie
  ///
  /// Le code ouvrait une connexion GATT dès la **première** annonce d'un
  /// inconnu — donc avec chaque passant, chaque voiture qui s'arrête au feu,
  /// chaque téléphone d'une salle d'attente. C'était l'objection de Jay
  /// (2026-08-18), et elle est fondée : une poignée de main coûte une connexion,
  /// une négociation de MTU, une découverte de services et deux signatures.
  ///
  /// On exige donc [PresenceRules.stableAfter] de contact continu. La mesure
  /// est une **durée**, pas un compte d'annonces : l'advertising tourne à
  /// ~100 ms, donc « 15 pings » serait atteint en moins de deux secondes.
  Future<void> _maybeOpenLink(PeerSession session, String peerHex) async {
    if (session.channel != null || session.connecting) return;
    if (session.snapshot != null) return;

    final now = _clock();
    if (!session.isStable(now)) return;

    // ⚠️ **On compare avec notre identifiant PUBLIC**, pas avec un jeton d'ami :
    // ce chemin ne concerne que les inconnus, et un jeton d'ami n'est de toute
    // façon pas le même selon l'ami. Il faut une valeur unique et partagée par
    // les deux côtés pour que le départage soit stable.
    final myHex = FriendKeyBook.hex(await _identity.currentPublicPingId());
    final iInitiate = myHex.compareTo(peerHex) < 0;

    if (!iInitiate) {
      final since = session.awaitingSince;
      if (since == null) {
        session.awaitingSince = now;
        return;
      }
      if (now.difference(since) < passiveFallback) return;
      // L'autre n'y arrive pas. On prend la main plutôt que d'attendre
      // indéfiniment un rendez-vous qui n'aura jamais lieu.
    }

    session.awaitingSince = null;
    await _open(session);
  }

  Future<void> _open(PeerSession session) async {
    if (session.connecting) return;
    final channel = session.channel;
    if (channel != null && channel.stage != ChannelStage.closed) return;

    final address = session.advertAddress;
    session.connecting = true;
    _publish();
    try {
      // ⚠️ **Avec une échéance.** Une connexion GATT qui n'aboutit pas peut
      // rester sans réponse une trentaine de secondes côté Android — et si le
      // rappel natif se perd, pour toujours.
      await radio.connect(address).timeout(connectTimeout);
    } catch (_) {
      // Rien ici : le stade affiché dérive de `connecting`, qui vaut ENCORE
      // `true` à cet instant. Un `_publish()` posé dans ce `catch` calculait
      // donc une signature inchangée et ne publiait rien — une ligne qui
      // mentait sur son intention (audit du 2026-08-18, point D).
    } finally {
      // L'état ne change qu'ici, donc c'est ici qu'on publie.
      session.connecting = false;
      _publish();
    }
  }

  /// Un lien s'ouvre.
  ///
  /// ## ⚠️ Une session a AU PLUS un lien
  ///
  /// Deux appareils peuvent se connecter en même temps — c'est même fréquent
  /// depuis le repli passif. Chacun reçoit alors deux événements de lien pour le
  /// même pair. L'ancien code écrasait le canal sans condition : l'émetteur
  /// chiffrait avec l'ancienne clé, le destinataire déchiffrait avec la
  /// nouvelle, et le message **disparaissait sans un mot**.
  ///
  /// La règle tient en une phrase parce que la session est unique : **un canal
  /// vivant ne se remplace jamais, et le lien de trop se referme côté radio.**
  Future<void> _onLinkUp(String linkId, int mtu, bool incoming) async {
    // Un lien est en soi une preuve de présence, et il peut précéder la
    // première annonce : le côté qui *reçoit* la connexion n'a souvent rien vu.
    final session = presence.touch(linkId);

    final existing = session.channel;
    if (existing != null && existing.stage != ChannelStage.closed) {
      TransportTrace.drop(
        DropKind.duplicateLink,
        linkId,
        incoming
            ? 'entrant, canal ${existing.stage.name}'
            : 'sortant, canal ${existing.stage.name}',
      );
      // Un second chemin physique vers un pair déjà relié : on le referme, sans
      // toucher à la session qui tient déjà un canal négocié.
      if (session.linkAddress != linkId) radio.disconnect(linkId);
      return;
    }

    // Un canal fermé laisse derrière lui un transport à refermer, sinon ses
    // envois en attente resteraient suspendus pour toujours.
    session.release();

    session.link = PeerLink(
      linkId: linkId,
      mtu: mtu,
      sendChunk: radio.send,
      onFrame: (id, frame) => unawaited(_onFrame(id, frame)),
      onDropped: (id, reason) =>
          TransportTrace.drop(DropKind.reassembly, id, reason),
    );
    session.channel = SecureChannel(linkId: linkId, identity: _identity);
    session.linkAddress = linkId;
    _publish();

    // ⚠️ **Les DEUX ouvrent, et personne n'attend.** Deux ouvertures qui se
    // croisent aboutissent au même couple de clés éphémères, donc à la même
    // session, et la réponse de trop ne change rien.
    await _tell(session, await session.channel!.open());
  }

  void _onLinkDown(String linkId) {
    final session = presence.byAddress(linkId);
    if (session == null) return;
    // Un AUTRE chemin est mort, pas le nôtre : ne rien défaire.
    if (session.linkAddress != null && session.linkAddress != linkId) return;
    session.release();
    // Le lien tombe, mais la RADIO peut encore voir le pair : on ne le fait pas
    // disparaître. Sa fraîcheur décidera.
    _publish();
  }

  // ------------------------------------------------------------------
  // Trames
  // ------------------------------------------------------------------

  /// ⚠️ **Ce traitement ne doit JAMAIS lever.** Il est appelé depuis le
  /// réassembleur, sans personne pour attendre son résultat : une exception y
  /// partirait dans le vide — invisible à l'exécution, aux tests, et à Jay.
  Future<void> _onFrame(String linkId, Uint8List bytes) async {
    try {
      await _handleFrame(linkId, bytes);
    } catch (e) {
      TransportTrace.drop(DropKind.handlerFailed, linkId, '$e');
      final session = presence.byAddress(linkId);
      if (session != null) {
        // Un état à moitié défait est plus difficile à diagnostiquer qu'un état
        // franchement cassé : le lien ET le canal partent ensemble.
        session.release();
        radio.disconnect(linkId);
      }
    }
  }

  Future<void> _handleFrame(String linkId, Uint8List bytes) async {
    final session = presence.byAddress(linkId);
    final channel = session?.channel;
    if (session == null || channel == null) {
      // La signature exacte du message fantôme : en face l'envoi a réussi, ici
      // il n'y a plus personne pour l'ouvrir.
      TransportTrace.drop(DropKind.noChannel, linkId, '${bytes.length} octets');
      return;
    }
    final frame = WireFrame.decode(bytes);
    if (frame == null) {
      TransportTrace.drop(
        DropKind.undecodable,
        linkId,
        '${bytes.length} octets',
      );
      return;
    }

    switch (frame) {
      // ⚠️ **Une OUVERTURE reçue l'emporte toujours sur la session en cours.**
      // Le pair ne l'envoie que s'il n'a plus de session avec nous ; refuser de
      // le suivre ne peut produire que du silence.
      case HelloFrame(
        :final version,
        :final ephemeralPublicKey,
        :final devicePublicKey,
        :final signature,
      ):
        final avantRekeys = channel.rekeys;
        final avantSession = channel.sessionSerial;
        final refus = await channel.acceptHello(
          version: version,
          peerEphemeral: ephemeralPublicKey,
          peerDeviceKey: devicePublicKey,
          signature: signature,
          weWillAnswer: true,
        );
        if (refus != null) {
          TransportTrace.drop(DropKind.handshakeRefused, linkId, refus);
          await _tell(session, ByeFrame(refus));
          radio.disconnect(linkId);
          return;
        }
        if (channel.rekeys != avantRekeys) {
          TransportTrace.drop(
            DropKind.sessionRebuilt,
            linkId,
            'le pair avait perdu la sienne (${channel.rekeys}e fois)',
          );
          // Une session neuve est une session sans profil envoyé.
          session.profileSent = false;
        }
        await _tell(session, await channel.answer());
        if (channel.sessionSerial != avantSession) {
          await _sendProfile(session);
        }

      case HelloAckFrame(
        :final version,
        :final ephemeralPublicKey,
        :final devicePublicKey,
        :final signature,
      ):
        final avantAck = channel.sessionSerial;
        final refus = await channel.acceptHello(
          version: version,
          peerEphemeral: ephemeralPublicKey,
          peerDeviceKey: devicePublicKey,
          signature: signature,
          // Nous ne répondons pas à une réponse : renouveler notre clé
          // éphémère ici la rendrait inconnue du pair.
          weWillAnswer: false,
        );
        if (refus != null) {
          TransportTrace.drop(DropKind.handshakeRefused, linkId, refus);
          await _tell(session, ByeFrame(refus));
          radio.disconnect(linkId);
          return;
        }
        if (channel.sessionSerial != avantAck) {
          session.profileSent = false;
          await _sendProfile(session);
        }

      case EncryptedFrame():
        final message = await channel.decrypt(frame);
        if (message == null) {
          TransportTrace.drop(
            DropKind.decryptRefused,
            linkId,
            'compteur ${frame.counter}, canal ${channel.stage.name}',
          );
          return;
        }
        await _onMessage(session, message);

      case ByeFrame():
        radio.disconnect(linkId);
    }
  }

  Future<void> _onMessage(PeerSession session, PeerMessage message) async {
    if (message is ProfileMessage) {
      await _onProfile(session, message);
      return;
    }
    // ⚠️ **L'identité appartient à la SESSION, pas à la présence.** Elle est
    // établie une fois par la poignée de main et le profil signé ; elle ne doit
    // pas dépendre d'une entrée de proximité qui va et vient.
    final snapshot = session.snapshot;
    if (snapshot == null) {
      // Sans identité, on ne saurait ni l'afficher, ni le ranger, ni décider
      // s'il a le droit d'exister.
      TransportTrace.drop(
        DropKind.beforeProfile,
        session.address,
        '${message.runtimeType}, profil pas encore reçu',
      );
      return;
    }
    TransportTrace.noteDelivered();
    _emit(PeerMessageReceived(session.address, snapshot, message));
  }

  Future<void> _onProfile(PeerSession session, ProfileMessage profile) async {
    final channel = session.channel;
    if (channel == null) return;

    // ⚠️ Deux vérifications, et il en faut DEUX. La signature prouve QUI a
    // écrit le profil ; la comparaison avec la clé de la poignée de main prouve
    // QUI est en face. La première seule ne dit rien d'utile : n'importe qui
    // pourrait rejouer le profil signé d'un autre, capté ailleurs.
    final signatureOk = await ProximityIdentity.verify(
      ProfileMessage.signedPayload(profile.userId, profile.username),
      profile.signature,
      profile.devicePublicKey,
    );
    if (!signatureOk || !channel.isPeerDeviceKey(profile.devicePublicKey)) {
      TransportTrace.drop(
        DropKind.profileRefused,
        session.address,
        signatureOk
            ? 'clé différente de la poignée de main'
            : 'signature invalide',
      );
      await _tell(session, const ByeFrame('profil non authentifié'));
      radio.disconnect(session.address);
      return;
    }
    if (profile.userId == myUserId) {
      // Notre propre annonce, renvoyée par un relais.
      TransportTrace.drop(DropKind.ownProfile, session.address);
      _close(session);
      return;
    }

    final result = presence.identify(session, profile.toSnapshot());
    if (result.merged != null) _closeTransport(result.merged!);
    final live = result.session;
    _emit(PeerIdentified(live.address, live.snapshot!));
    _publish();
  }

  /// ⚠️ **Notre profil est la PREMIÈRE trame applicative d'une session.**
  ///
  /// Sans cet invariant, un certificat de croisement pouvait partir avant notre
  /// profil : en face, on ne savait pas encore qui parlait et la trame était
  /// jetée — alors que `certified` était déjà marqué, donc plus aucune nouvelle
  /// tentative. Le croisement était perdu pour de bon, en silence.
  Future<void> _sendProfile(PeerSession session) async {
    final channel = session.channel;
    if (channel == null || channel.stage != ChannelStage.established) return;
    final me = await myProfile();
    final signature = await _identity.sign(
      ProfileMessage.signedPayload(me.userId, me.username),
    );
    session.profileSent = true;
    await _sendWire(
      session,
      await channel.encrypt(
        ProfileMessage(
          userId: me.userId,
          username: me.username,
          tagName: me.tagName,
          devicePublicKey: await _identity.edPublicKey(),
          signature: signature,
        ),
      ),
    );
    TransportTrace.noteHandshake();
  }

  // ------------------------------------------------------------------
  // Sortie
  // ------------------------------------------------------------------

  /// Envoie un message applicatif à un pair, par son adresse.
  ///
  /// Lève si le canal n'est pas établi — **volontairement**. Un envoi qui échoue
  /// en silence est ce qui a fait perdre des demandes d'amis sans que personne
  /// ne le sache.
  Future<void> send(String address, PeerMessage message) async {
    final session = presence.byAddress(address);
    final channel = session?.channel;
    if (session == null ||
        channel == null ||
        channel.stage != ChannelStage.established) {
      throw StateError('aucun canal établi avec $address');
    }
    // Notre profil d'abord, **toujours**.
    if (!session.profileSent) await _sendProfile(session);
    await _sendWire(session, await channel.encrypt(message));
  }

  /// Envoie à un utilisateur, en ouvrant le lien si besoin.
  Future<void> sendToUser(String userId, PeerMessage message) async {
    final session = presence.byUser(userId);
    if (session == null || !session.isFresh(_clock())) {
      throw StateError('$userId n\'est pas à portée');
    }
    await ensureChannel(session.address);
    await send(session.address, message);
  }

  /// Garantit un canal établi avec [address], en attendant la poignée de main.
  ///
  /// ⚠️ **Contourne le seuil de stabilité, et c'est voulu** : c'est le chemin
  /// des gestes explicites de l'utilisateur (demander en ami, écrire). Quand
  /// quelqu'un agit, on n'attend pas dix secondes de contact continu.
  Future<void> ensureChannel(String address) async {
    final session = presence.byAddress(address);
    if (session == null) throw StateError('aucun pair sur $address');
    if (session.hasChannel) return;
    if (session.channel == null) await _open(session);

    // La poignée de main est asynchrone : on attend qu'elle aboutisse, avec une
    // borne. Sans borne, un pair muet bloquerait l'appelant pour toujours.
    final deadline = _clock().add(const Duration(seconds: 8));
    while (_clock().isBefore(deadline)) {
      if (session.hasChannel) return;
      if (session.channel?.stage == ChannelStage.closed) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw StateError('poignée de main impossible avec $address');
  }

  Future<void> _sendWire(PeerSession session, WireFrame frame) async {
    final link = session.link;
    if (link == null) throw StateError('aucun lien ${session.address}');
    await link.send(frame.encode());
  }

  /// Trame de SERVICE (poignée de main, congé) : son échec n'intéresse personne.
  ///
  /// ⚠️ Deux régimes, et la distinction est délibérée. Un `hello` qui meurt avec
  /// son lien est un non-événement. Un message **applicatif** perdu, lui, doit
  /// toujours remonter.
  Future<void> _tell(PeerSession session, WireFrame frame) async {
    try {
      await _sendWire(session, frame);
    } catch (_) {
      // Lien déjà tombé : rien à faire, et rien à signaler.
    }
  }

  // ------------------------------------------------------------------
  // Entretien
  // ------------------------------------------------------------------

  /// Ferme **tout** pour un pair : transport, radio, registre. Un seul geste.
  void _close(PeerSession session) {
    _closeTransport(session);
    presence.remove(session);
  }

  void _closeTransport(PeerSession session) {
    if (session.hasChannel) {
      TransportTrace.drop(
        DropKind.sessionDropped,
        session.address,
        'session refermée',
      );
    }
    session.release();
    for (final address in session.addresses) {
      radio.disconnect(address);
    }
  }

  /// Battement régulier : rotation de l'index, pairs oubliés, replis armés.
  Future<void> tick() async {
    final slot = ProximityIdentity.slotIndex(_clock());
    if (slot != _slot) await refreshFriends();

    for (final session in presence.expired()) {
      final peer = session.toPresence();
      _close(session);
      _emit(PeerLost(peer));
    }

    final now = _clock();
    for (final session in presence.sessions.toList()) {
      if (session.snapshot != null || session.channel != null) continue;
      final since = session.awaitingSince;
      if (since == null) continue;
      if (now.difference(since) >= passiveFallback) {
        session.awaitingSince = null;
        await _open(session);
      }
    }

    _publish();
  }

  /// Publie le constat de présence. **Un seul chemin vers « la présence a
  /// bougé ».**
  ///
  /// ## ⚠️ Un seul chemin, et une seule responsabilité
  ///
  /// Sept endroits émettaient `PresenceChanged` à la main, chacun quand son
  /// auteur y pensait : une observation, une connexion en cours, un lien qui
  /// monte, un lien qui tombe, un profil accepté… D'où des rafraîchissements en
  /// double sur un même changement, et **aucun** quand un pair cessait
  /// simplement d'être frais — personne n'émet pour un non-événement.
  ///
  /// ## ⚠️ Ce qui a changé le 2026-08-20 — règle de dissociation de Jay
  ///
  /// Cette méthode filtrait sur une signature `adresse:stade`, c'est-à-dire
  /// qu'**une couche d'acquisition décidait à la place de l'affichage** si
  /// l'écran devait se redessiner. Deux conséquences :
  ///
  /// - la bande, la tendance et la distance ne se rafraîchissaient jamais pour
  ///   un pair identifié et immobile (audit du 2026-08-18, point C) ;
  /// - toute nouveauté visible à l'écran obligeait à venir modifier **ce
  ///   fichier**, qui n'a aucune raison de connaître les champs d'une tuile.
  ///
  /// Le réseau publie donc ce qu'il constate, fidèlement. C'est
  /// `presence_feed.dart` qui compare, avec sa propre définition de
  /// « différent » — l'égalité de ce qu'une tuile affiche. Le chemin est bon
  /// marché de bout en bout : ni disque, ni réseau, rien qu'une comparaison de
  /// valeurs.
  void _publish() => _emit(const PresenceChanged());

  void _emit(PeerEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Les ORDRES qu'on peut donner à la radio.
///
/// Interface étroite et volontairement pauvre : c'est ce qui permet de faire
/// tourner [PeerNetwork] en test, sans Bluetooth, avec deux réseaux branchés
/// l'un sur l'autre.
abstract class RadioCommands {
  Future<int> connect(String address);
  void disconnect(String linkId);
  Future<void> send(String linkId, Uint8List chunk);
}
