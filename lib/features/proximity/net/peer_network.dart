import 'dart:async';
import 'dart:typed_data';

import '../ping_store.dart';
import '../proximity_identity.dart';
import 'peer_link.dart';
import 'presence_tracker.dart';
import 'proximity_protocol.dart';
import 'radio_status.dart';
import 'secure_channel.dart';

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

/// Un pair inconnu s'est révélé, ou un ami a confirmé son profil.
class PeerIdentified extends PeerEvent {
  const PeerIdentified(this.address, this.snapshot, {required this.isFriend});
  final String address;
  final PingPeerSnapshot snapshot;
  final bool isFriend;
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
/// Il transforme un flux d'événements radio en un flux d'événements de pairs. Il
/// ouvre les liens, tient un canal chiffré par lien, réassemble les trames,
/// vérifie les identités, et publie ce qui a du sens.
///
/// ## Ce qu'il ne fait pas
///
/// Il ne sait pas ce qu'est un certificat de croisement, un wave, ou une
/// demande d'ami. Il transporte des [PeerMessage] et les publie ; ce sont les
/// fonctions, au-dessus, qui décident quoi en faire.
///
/// C'est la ligne que l'ancien `proximity_service.dart` ne tenait pas : il
/// faisait les deux, et ses 1040 lignes n'ont jamais pu être testées.
class PeerNetwork {
  PeerNetwork({
    required this.myUserId,
    required this.myProfile,
    required this.radio,
    ProximityIdentity? identity,
    FriendKeyStore? keyBook,
    DateTime Function()? clock,
  }) : _identity = identity ?? ProximityIdentity(),
       _keyBook = keyBook ?? FriendKeyBook(),
       _clock = clock ?? DateTime.now,
       presence = PresenceTracker(clock: clock);

  /// Mon identifiant. Sert à décider qui initie et à signer.
  final String myUserId;

  /// Mon mini-profil, envoyé dans le tunnel chiffré.
  final Future<PingPeerSnapshot> Function() myProfile;

  final RadioCommands radio;
  final ProximityIdentity _identity;
  final FriendKeyStore _keyBook;
  final DateTime Function() _clock;

  final PresenceTracker presence;

  final _links = <String, PeerLink>{};
  final _channels = <String, SecureChannel>{};
  final _connecting = <String>{};

  /// Adresses pour lesquelles on attend que l'AUTRE ouvre le lien.
  ///
  /// ⚠️ **C'est le repli qui manquait** (défaut B4). L'initiateur était choisi
  /// par comparaison lexicale des identifiants diffusés, et le côté passif
  /// attendait — indéfiniment. Si l'initiateur n'y arrivait pas (écran éteint,
  /// scan bridé, pile GATT occupée), la paire ne se rencontrait **jamais**, et
  /// les deux écrans restaient vides sans que rien ne le signale.
  final _awaiting = <String, DateTime>{};

  /// Au bout de ce délai, le côté passif prend l'initiative.
  static const passiveFallback = Duration(seconds: 12);

  /// Au-delà, on considère que le lien ne s'ouvrira pas.
  static const connectTimeout = Duration(seconds: 15);

  /// Index ID rotatif → ami, reconstruit à chaque créneau.
  Map<String, FriendKeys> _friendIndex = {};
  int _slot = -1;

  final _events = StreamController<PeerEvent>.broadcast();
  Stream<PeerEvent> get events => _events.stream;

  Timer? _housekeeping;

  Future<void> start() async {
    await refreshFriends();
    _housekeeping ??= Timer.periodic(const Duration(seconds: 3), (_) => tick());
  }

  Future<void> dispose() async {
    _housekeeping?.cancel();
    _housekeeping = null;
    for (final link in _links.values) {
      link.close();
    }
    _links.clear();
    for (final channel in _channels.values) {
      channel.close();
    }
    _channels.clear();
    presence.clear();
    await _events.close();
  }

  /// Recharge le carnet d'amis et son index rotatif.
  Future<void> refreshFriends() async {
    _slot = ProximityIdentity.slotIndex(_clock());
    _friendIndex = await _keyBook.rotatingIndex(_slot);
  }

  // ------------------------------------------------------------------
  // Entrée : les constats de la radio
  // ------------------------------------------------------------------

  Future<void> onRadioEvent(RadioEvent event) async {
    switch (event) {
      case RadioStatusEvent(:final status):
        // La radio s'arrête : la présence n'est plus qu'un souvenir, et un
        // souvenir présenté comme une observation est exactement ce qu'on a
        // passé la journée à supprimer.
        if (!status.isDetecting && presence.length > 0) {
          presence.clear();
          _emit(const PresenceChanged());
        }
      case RadioScan(:final address, :final advertId, :final rssi):
        await _onScan(address, advertId, rssi);
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
        _links[linkId]?.receive(data);
    }
  }

  Future<void> _onScan(String address, Uint8List advertId, int rssi) async {
    final hex = _hex(advertId);
    final friend = _friendIndex[hex];

    final before = presence.byAddress(address)?.stage;
    presence.observe(
      address,
      rssi,
      friend: friend == null
          ? null
          : PingPeerSnapshot(
              userId: friend.userId,
              username: friend.username,
              tagName: friend.tagName,
              verified: true,
            ),
    );
    if (before != presence.byAddress(address)?.stage) {
      _emit(const PresenceChanged());
    }

    // Un ami reconnu n'a PAS besoin d'un lien pour être affiché. Il en faudra
    // un pour le certificat de croisement — c'est `tick` qui le décidera, après
    // les 10 s de contact continu, et pas avant.
    if (friend != null) return;

    await _maybeOpenLink(address, hex);
  }

  /// Décide qui ouvre le lien avec un inconnu.
  ///
  /// L'asymétrie vient de la comparaison des identifiants diffusés : exactement
  /// un des deux initie. **Mais le côté passif arme une échéance** — voir
  /// [_awaiting].
  Future<void> _maybeOpenLink(String address, String peerHex) async {
    if (_channels.containsKey(address) || _connecting.contains(address)) return;
    final peer = presence.byAddress(address);
    if (peer != null && peer.stage == PresenceStage.identified) return;

    final myHex = _hex(await _identity.currentRotatingId());
    final iInitiate = myHex.compareTo(peerHex) < 0;

    if (!iInitiate) {
      final since = _awaiting[address];
      if (since == null) {
        _awaiting[address] = _clock();
        return;
      }
      if (_clock().difference(since) < passiveFallback) return;
      // L'autre n'y arrive pas. On prend la main plutôt que d'attendre
      // indéfiniment un rendez-vous qui n'aura jamais lieu.
    }

    _awaiting.remove(address);
    await _open(address);
  }

  Future<void> _open(String address) async {
    _connecting.add(address);
    presence.markIdentifying(address);
    _emit(const PresenceChanged());
    try {
      // ⚠️ **Avec une échéance.** Une connexion GATT qui n'aboutit pas peut
      // rester sans réponse une trentaine de secondes côté Android — et si le
      // rappel natif se perd, pour toujours. Sans borne ici, `_connecting`
      // garderait l'adresse indéfiniment et **plus aucune tentative** ne serait
      // possible avec ce pair.
      await radio.connect(address).timeout(connectTimeout);
    } catch (_) {
      presence.markIdentificationFailed(address);
      _emit(const PresenceChanged());
    } finally {
      _connecting.remove(address);
    }
  }

  Future<void> _onLinkUp(String linkId, int mtu, bool incoming) async {
    _links[linkId] = PeerLink(
      linkId: linkId,
      mtu: mtu,
      sendChunk: radio.send,
      onFrame: (id, frame) => unawaited(_onFrame(id, frame)),
    );
    final channel = SecureChannel(
      linkId: linkId,
      initiator: !incoming,
      identity: _identity,
    );
    _channels[linkId] = channel;
    presence.markIdentifying(linkId);
    _emit(const PresenceChanged());

    // L'initiateur ouvre la poignée de main ; le répondeur attend le `hello`
    // pour répondre avec le sien — sinon les deux parleraient en même temps et
    // dériveraient deux clés différentes.
    if (!incoming) {
      await _tell(linkId, await channel.hello());
    }
  }

  void _onLinkDown(String linkId) {
    _links.remove(linkId)?.close();
    _channels.remove(linkId)?.close();
    // Le lien tombe, mais la RADIO peut encore voir le pair : on redescend à
    // « détecté », on ne le fait pas disparaître.
    presence.markIdentificationFailed(linkId);
    _emit(const PresenceChanged());
  }

  // ------------------------------------------------------------------
  // Trames
  // ------------------------------------------------------------------

  /// ⚠️ **Ce traitement ne doit JAMAIS lever.**
  ///
  /// Il est appelé depuis le réassembleur, sans personne pour attendre son
  /// résultat : une exception y partirait dans le vide — invisible à
  /// l'exécution, invisible aux tests, invisible à Jay. C'est la forme la plus
  /// pure du défaut qu'on passe la journée à supprimer.
  ///
  /// Un échec de traitement rend donc le lien **inutilisable**, et on le ferme :
  /// un canal à moitié vivant ne mène qu'à des symptômes inexplicables plus
  /// tard.
  Future<void> _onFrame(String linkId, Uint8List bytes) async {
    try {
      await _handleFrame(linkId, bytes);
    } catch (_) {
      _links[linkId]?.close();
      radio.disconnect(linkId);
    }
  }

  Future<void> _handleFrame(String linkId, Uint8List bytes) async {
    final channel = _channels[linkId];
    if (channel == null) return;
    final frame = WireFrame.decode(bytes);
    if (frame == null) return;

    switch (frame) {
      case HelloFrame(
        :final version,
        :final ephemeralPublicKey,
        :final devicePublicKey,
        :final signature,
      ):
        final refus = await channel.acceptHello(
          version: version,
          peerEphemeral: ephemeralPublicKey,
          peerDeviceKey: devicePublicKey,
          signature: signature,
        );
        if (refus != null) {
          await _tell(linkId, ByeFrame(refus));
          radio.disconnect(linkId);
          return;
        }
        await _tell(linkId, await channel.hello());
        await _sendProfile(linkId, channel);

      case HelloAckFrame(
        :final version,
        :final ephemeralPublicKey,
        :final devicePublicKey,
        :final signature,
      ):
        final refus = await channel.acceptHello(
          version: version,
          peerEphemeral: ephemeralPublicKey,
          peerDeviceKey: devicePublicKey,
          signature: signature,
        );
        if (refus != null) {
          await _tell(linkId, ByeFrame(refus));
          radio.disconnect(linkId);
          return;
        }
        await _sendProfile(linkId, channel);

      case EncryptedFrame():
        final message = await channel.decrypt(frame);
        if (message != null) await _onMessage(linkId, channel, message);

      case ByeFrame():
        radio.disconnect(linkId);
    }
  }

  Future<void> _onMessage(
    String linkId,
    SecureChannel channel,
    PeerMessage message,
  ) async {
    if (message is ProfileMessage) {
      await _onProfile(linkId, channel, message);
      return;
    }
    final peer = presence.byAddress(linkId);
    final snapshot = peer?.snapshot;
    // Tout le reste exige de savoir À QUI on parle. Un message reçu avant le
    // profil est ignoré : sans identité, on ne saurait ni l'afficher, ni le
    // ranger, ni décider s'il a le droit d'exister.
    if (snapshot == null) return;
    _emit(PeerMessageReceived(linkId, snapshot, message));
  }

  Future<void> _onProfile(
    String linkId,
    SecureChannel channel,
    ProfileMessage profile,
  ) async {
    // ⚠️ Deux vérifications, et il en faut DEUX.
    //
    // 1. La signature prouve que le profil a bien été écrit par le porteur de
    //    cette clé d'appareil.
    // 2. Cette clé doit être celle qui a signé la POIGNÉE DE MAIN — sinon
    //    n'importe qui pourrait rejouer le profil signé de quelqu'un d'autre,
    //    capté ailleurs, dans une session bien à lui.
    //
    // La première seule ne prouve rien d'utile : elle dit qui a écrit, pas qui
    // est en face.
    final signatureOk = await ProximityIdentity.verify(
      ProfileMessage.signedPayload(profile.userId, profile.username),
      profile.signature,
      profile.devicePublicKey,
    );
    if (!signatureOk || !channel.isPeerDeviceKey(profile.devicePublicKey)) {
      await _tell(linkId, const ByeFrame('profil non authentifié'));
      radio.disconnect(linkId);
      return;
    }
    if (profile.userId == myUserId) {
      // Notre propre annonce, renvoyée par un relais : rien à en faire.
      radio.disconnect(linkId);
      return;
    }

    final snapshot = profile.toSnapshot();
    presence.markIdentified(linkId, snapshot);
    final isFriend = (await _keyBook.all()).containsKey(profile.userId);
    _emit(PeerIdentified(linkId, snapshot, isFriend: isFriend));
    _emit(const PresenceChanged());
  }

  Future<void> _sendProfile(String linkId, SecureChannel channel) async {
    final me = await myProfile();
    final signature = await _identity.sign(
      ProfileMessage.signedPayload(me.userId, me.username),
    );
    await send(
      linkId,
      ProfileMessage(
        userId: me.userId,
        username: me.username,
        tagName: me.tagName,
        devicePublicKey: await _identity.edPublicKey(),
        signature: signature,
      ),
    );
  }

  // ------------------------------------------------------------------
  // Sortie
  // ------------------------------------------------------------------

  /// Envoie un message applicatif à un pair, par son adresse de lien.
  ///
  /// Lève si le canal n'est pas établi — **volontairement**. Un envoi qui échoue
  /// en silence est ce qui a fait perdre des demandes d'amis sans que personne
  /// ne le sache.
  Future<void> send(String linkId, PeerMessage message) async {
    final channel = _channels[linkId];
    if (channel == null || channel.stage != ChannelStage.established) {
      throw StateError('aucun canal établi avec $linkId');
    }
    await _sendWire(linkId, await channel.encrypt(message));
  }

  /// Envoie à un utilisateur, en ouvrant le lien si besoin.
  Future<void> sendToUser(String userId, PeerMessage message) async {
    final peer = presence.byUser(userId);
    if (peer == null) {
      throw StateError('$userId n\'est pas à portée');
    }
    await ensureChannel(peer.address);
    await send(peer.address, message);
  }

  /// Garantit un canal établi avec [address], en attendant la poignée de main.
  Future<void> ensureChannel(String address) async {
    final existing = _channels[address];
    if (existing != null && existing.stage == ChannelStage.established) return;
    if (existing == null) await _open(address);

    // La poignée de main est asynchrone : on attend qu'elle aboutisse, avec une
    // borne. Sans borne, un pair muet bloquerait l'appelant pour toujours.
    final deadline = _clock().add(const Duration(seconds: 8));
    while (_clock().isBefore(deadline)) {
      final channel = _channels[address];
      if (channel?.stage == ChannelStage.established) return;
      if (channel?.stage == ChannelStage.closed) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw StateError('poignée de main impossible avec $address');
  }

  Future<void> _sendWire(String linkId, WireFrame frame) async {
    final link = _links[linkId];
    if (link == null) throw StateError('aucun lien $linkId');
    await link.send(frame.encode());
  }

  /// Trame de SERVICE (poignée de main, congé) : son échec n'intéresse
  /// personne.
  ///
  /// ⚠️ Deux régimes, et la distinction est délibérée. Un `hello` ou un `bye`
  /// qui meurt avec son lien est un non-événement : le lien est mort, il n'y a
  /// rien à sauver et rien à dire. Un message **applicatif** perdu, lui, doit
  /// toujours remonter — c'est exactement ce silence qui faisait disparaître
  /// des demandes d'amis sans que personne ne le sache (défaut A3).
  Future<void> _tell(String linkId, WireFrame frame) async {
    try {
      await _sendWire(linkId, frame);
    } catch (_) {
      // Lien déjà tombé : rien à faire, et rien à signaler.
    }
  }

  // ------------------------------------------------------------------
  // Entretien
  // ------------------------------------------------------------------

  /// Battement régulier : rotation de l'index, pairs partis, replis en attente.
  Future<void> tick() async {
    final slot = ProximityIdentity.slotIndex(_clock());
    if (slot != _slot) await refreshFriends();

    final gone = presence.prune();
    for (final peer in gone) {
      _links.remove(peer.address)?.close();
      _channels.remove(peer.address)?.close();
      _awaiting.remove(peer.address);
      _emit(PeerLost(peer));
    }
    if (gone.isNotEmpty) _emit(const PresenceChanged());

    // Les replis armés dont l'échéance est passée.
    for (final address in _awaiting.keys.toList()) {
      final peer = presence.byAddress(address);
      if (peer == null || peer.stage == PresenceStage.identified) {
        _awaiting.remove(address);
        continue;
      }
      if (_clock().difference(_awaiting[address]!) >= passiveFallback) {
        _awaiting.remove(address);
        await _open(address);
      }
    }
  }

  void _emit(PeerEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
