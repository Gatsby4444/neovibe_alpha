import 'dart:async';
import 'dart:typed_data';

import '../ping_store.dart';
import '../proximity_identity.dart';
import 'peer_link.dart';
import 'presence_tracker.dart';
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
/// ⚠️ **Il n'y a pas de `isFriend` ici, et c'est délibéré (2026-08-17).**
///
/// Il y en avait un. `PeerNetwork` interrogeait le carnet pour le calculer, et
/// le publiait — donc une notion **produit** descendait sous la frontière que
/// ce fichier déclare lui-même tenir : *« en dessous on parle radio, trames et
/// clés ; au-dessus on parle profils, messages et certificats »*.
///
/// Le coût a été concret : la même question recevait deux réponses (l'événement
/// et l'entrée de présence), elles divergeaient, et le bouton lisait la
/// mauvaise. Le réseau dit désormais **qui**, jamais **ce que cette personne
/// est pour moi** — cette question-là se pose au carnet, au moment du rendu.
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
  /// ⚠️ **[keyBook] est OBLIGATOIRE, et c'est le correctif du 2026-08-17.**
  ///
  /// Il valait `keyBook ?? FriendKeyBook()`. Ce `??` était la **troisième**
  /// instance du carnet — la plus dangereuse, parce qu'elle se créait toute
  /// seule, sans qu'aucun appelant ne l'ait demandée, avec son propre cache
  /// mémoire sur le même fichier. Un défaut commode qui fabrique un état
  /// partagé est un défaut qui finira par diverger.
  ///
  /// Aucun appelant ne s'en servait — mais rien ne l'empêchait, et c'est
  /// précisément ce genre de porte ouverte qu'on ferme au lieu de la surveiller.
  PeerNetwork({
    required this.myUserId,
    required this.myProfile,
    required this.radio,
    required FriendKeyStore keyBook,
    ProximityIdentity? identity,
    DateTime Function()? clock,
    // Le champ est privé : un paramètre formel initialisant l'exposerait sous
    // son nom privé, que les appelants ne peuvent pas nommer.
    // ignore: prefer_initializing_formals
  }) : _keyBook = keyBook,
       _identity = identity ?? ProximityIdentity(),
       _clock = clock ?? DateTime.now {
    // La présence peut demander au transport si une adresse porte encore un
    // lien : c'est ce qui lui permet de ne pas abandonner une session vivante.
    presence = PresenceTracker(
      clock: clock,
      hasLiveLink: (address) =>
          _channels[address]?.stage == ChannelStage.established,
    );
  }

  /// Mon identifiant. Sert à décider qui initie et à signer.
  final String myUserId;

  /// Mon mini-profil, envoyé dans le tunnel chiffré.
  final Future<PingPeerSnapshot> Function() myProfile;

  final RadioCommands radio;
  final ProximityIdentity _identity;
  final FriendKeyStore _keyBook;
  final DateTime Function() _clock;

  late final PresenceTracker presence;

  final _links = <String, PeerLink>{};
  final _channels = <String, SecureChannel>{};

  /// Qui est au bout de chaque lien, **selon la session elle-même**.
  ///
  /// ⚠️ **La livraison demandait cette réponse à la PRÉSENCE, et c'était le
  /// défaut.** Relevé sur l'appareil de Jay le 2026-08-17 (v0.9.118) :
  /// `message reçu avant le profil — ChatMessage, présence ABSENTE`. Deux
  /// messages perdus, alors que le canal déchiffrait parfaitement.
  ///
  /// La présence parle de **proximité**, et ses entrées vont et viennent : une
  /// adresse abandonnée par la fusion (Android renouvelle sa MAC en
  /// permanence), une remise à zéro quand la radio s'arrête, un élagage. Rien
  /// de tout ça ne devrait faire disparaître une conversation en cours.
  ///
  /// L'identité, elle, est établie une fois par la poignée de main et le profil
  /// signé — c'est une propriété de la **session**. On la range donc avec la
  /// session, et la livraison ne consulte plus la présence.
  ///
  /// C'est la même règle qu'au petit matin, un cran plus bas : *la présence dit
  /// OÙ, jamais QUI.*
  final _identities = <String, PingPeerSnapshot>{};
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
    // ⚠️ **On s'abonne au carnet, on ne le relit pas à heure fixe.**
    //
    // Défaut du 2026-08-17 : l'index rotatif était construit ici, **puis** la
    // synchronisation téléchargeait les clés — sans que rien ne le dise. Il
    // n'était reconstruit qu'au changement de créneau, toutes les 15 minutes,
    // et depuis un cache périmé : donc jamais. Un ami restait un inconnu
    // jusqu'au prochain lancement de l'app.
    //
    // Un abonnement supprime la course : peu importe qui arrive en premier, du
    // réseau ou des clés.
    _keyBook.changes.addListener(_onBookChanged);
    await refreshFriends();
    _housekeeping ??= Timer.periodic(const Duration(seconds: 3), (_) => tick());
  }

  void _onBookChanged() => unawaited(refreshFriends());

  Future<void> dispose() async {
    _keyBook.changes.removeListener(_onBookChanged);
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
    _identities.clear();
    presence.clear();
    await _events.close();
  }

  /// Y a-t-il un canal capable de chiffrer avec cette adresse ?
  ///
  /// Exposé pour les tests : c'est la condition exacte sur laquelle s'appuie le
  /// balayage des certificats, et donc celle qu'il faut pouvoir reproduire.
  bool hasEstablishedChannel(String address) =>
      _channels[address]?.stage == ChannelStage.established;

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
        final link = _links[linkId];
        if (link == null) {
          // ⚠️ Arrive normalement : les deux côtés s'ouvrent, et l'un des deux
          // peut parler avant que notre événement de lien ne soit remonté. Ce
          // n'est pas grave — notre propre ouverture rattrapera — mais si ce
          // compteur s'envole, c'est que des liens montent sans être vus.
          TransportTrace.drop(DropKind.noLink, linkId, '${data.length} octets');
          return;
        }
        link.receive(data);
    }
  }

  Future<void> _onScan(
    String address,
    Uint8List advertId,
    int rssi,
    int txPower,
  ) async {
    final hex = _hex(advertId);
    final friend = _friendIndex[hex];

    final before = presence.byAddress(address)?.stage;
    presence.observe(
      address,
      rssi,
      txPower: txPower,
      friend: friend == null
          ? null
          : PingPeerSnapshot(
              userId: friend.userId,
              username: friend.username,
              tagName: friend.tagName,
              verified: true,
            ),
    );
    // La fusion a pu abandonner une adresse à l'instant : on ferme son
    // transport **maintenant**, pas au battement d'après.
    _closeMergedAway();
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
    // Déjà relié : ouvrir un second lien produirait exactement le doublon que
    // `_onLinkUp` doit maintenant refuser. Autant ne pas le créer.
    final channel = _channels[address];
    if (channel != null && channel.stage != ChannelStage.closed) return;
    if (_connecting.contains(address)) return;

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

  /// Un lien s'ouvre.
  ///
  /// ## ⚠️ Le premier lien gagne, et un canal ÉTABLI ne se remplace jamais
  ///
  /// **Défaut du 2026-08-16, relevé par Jay** : *« charles envoie des messages
  /// fantômes à mimi qui ne les reçoit jamais »*, et en face *« poignée de main
  /// impossible »*.
  ///
  /// Cette méthode écrasait `_channels[linkId]` **sans condition**. Or deux
  /// appareils peuvent très bien se connecter **en même temps** — c'est même
  /// devenu fréquent depuis le repli passif de 12 s, qui fait prendre
  /// l'initiative au second si le premier tarde. Chacun reçoit alors DEUX
  /// événements de lien pour le même pair, et le second détruisait la session
  /// déjà négociée.
  ///
  /// Conséquence exacte : l'émetteur chiffrait avec la clé de l'ancienne
  /// session, le destinataire tentait de déchiffrer avec la nouvelle, et
  /// `decrypt` rendait `null`. Le message **disparaissait sans un mot** — ni
  /// erreur chez l'un, ni trace chez l'autre. Des messages fantômes.
  ///
  /// Deux règles en découlent, et elles suffisent :
  ///
  /// 1. **un canal établi ne se remplace jamais** — il porte une clé que le
  ///    pair utilise déjà ;
  /// 2. **le premier lien gagne** — un second lien vers un pair déjà relié est
  ///    un doublon, quel que soit son sens. S'il est vraiment mort,
  ///    `_onLinkDown` fera le ménage et la tentative suivante réussira.
  Future<void> _onLinkUp(String linkId, int mtu, bool incoming) async {
    final existing = _channels[linkId];
    if (existing != null && existing.stage != ChannelStage.closed) {
      // Déjà en relation avec ce pair : ce lien-ci est un doublon.
      TransportTrace.drop(
        DropKind.duplicateLink,
        linkId,
        incoming
            ? 'entrant, canal ${existing.stage.name}'
            : 'sortant, canal ${existing.stage.name}',
      );
      return;
    }
    // Un canal fermé laisse derrière lui un transport à refermer proprement,
    // sinon ses envois en attente resteraient suspendus pour toujours.
    _links.remove(linkId)?.close();
    _profileSent.remove(linkId);
    _identities.remove(linkId);

    _links[linkId] = PeerLink(
      linkId: linkId,
      mtu: mtu,
      sendChunk: radio.send,
      onFrame: (id, frame) => unawaited(_onFrame(id, frame)),
      // ⚠️ **Ce rappel existait et n'était branché nulle part.** Le
      // réassembleur savait dire ce qu'il jetait ; personne ne l'écoutait.
      onDropped: (id, reason) =>
          TransportTrace.drop(DropKind.reassembly, id, reason),
    );
    final channel = SecureChannel(linkId: linkId, identity: _identity);
    _channels[linkId] = channel;
    presence.markIdentifying(linkId);
    _emit(const PresenceChanged());

    // ⚠️ **Les DEUX ouvrent, et personne n'attend.**
    //
    // Seul celui qui avait composé le numéro ouvrait ; l'autre attendait un
    // `hello`. Deux conséquences, toutes deux silencieuses :
    //
    // 1. si ce `hello` se perdait — lien qui bat, réassemblage abandonné — le
    //    côté passif attendait **indéfiniment** avec un canal sans clé ;
    // 2. quand un pair reconstruisait sa session sur un lien que nous tenions
    //    déjà, aucun des deux ne parlait : lui parce qu'il était passif, nous
    //    parce que notre canal semblait encore bon.
    //
    // Ouvrir des deux côtés supprime l'attente au lieu de la surveiller.
    // `acceptHello` est conçue pour ça : deux ouvertures qui se croisent
    // aboutissent au **même** couple de clés éphémères, donc à la même session,
    // et la réponse de trop ne change rien (voir [SecureChannel.sessionSerial]).
    await _tell(linkId, await channel.open());
  }

  void _onLinkDown(String linkId) {
    _profileSent.remove(linkId);
    _identities.remove(linkId);
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
    } catch (e) {
      TransportTrace.drop(DropKind.handlerFailed, linkId, '$e');
      _identities.remove(linkId);
      // ⚠️ **Le canal part avec le lien.** On ne fermait que le lien : le canal
      // restait « établi » sur un transport mort. Deux conséquences, aucune
      // visible — `hasLiveLink` répondait oui, donc l'entretien gardait
      // indéfiniment un pair qui n'existait plus ; et tout envoi échouait sur
      // « lien fermé » alors que l'état du canal affirmait le contraire.
      //
      // Un état à moitié défait est plus difficile à diagnostiquer qu'un état
      // franchement cassé.
      _links.remove(linkId)?.close();
      _channels.remove(linkId)?.close();
      radio.disconnect(linkId);
    }
  }

  Future<void> _handleFrame(String linkId, Uint8List bytes) async {
    final channel = _channels[linkId];
    if (channel == null) {
      // ⚠️ **La signature exacte du message fantôme.** En face, l'envoi a
      // réussi ; ici, il n'y a plus personne pour l'ouvrir. Si ce compteur
      // bouge sur un appareil de Jay, c'est qu'une session a été démontée d'un
      // seul côté — et le journal dit quand.
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
      //
      // Le pair ne l'envoie que s'il n'a plus de session avec nous. Refuser de
      // le suivre — ce que faisait la règle « un canal établi ne se remplace
      // jamais » — ne pouvait produire que du silence : il chiffre avec une clé
      // que nous n'avons pas, nous refusons ses compteurs repartis de zéro, et
      // personne ne voit rien. (Quatrième cause de message fantôme, mesurée le
      // 2026-08-17 sur les deux appareils de Jay.)
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
          await _tell(linkId, ByeFrame(refus));
          radio.disconnect(linkId);
          return;
        }
        if (channel.rekeys != avantRekeys) {
          TransportTrace.drop(
            DropKind.sessionRebuilt,
            linkId,
            'le pair avait perdu la sienne (${channel.rekeys}e fois)',
          );
        }
        await _tell(linkId, await channel.answer());
        // Rien de nouveau : c'est une ouverture qui a croisé la nôtre, et nous
        // sommes déjà d'accord. Renvoyer le profil serait du trafic pour rien.
        if (channel.sessionSerial != avantSession) {
          await _sendProfile(linkId, channel);
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
          // éphémère ici la rendrait inconnue du pair, et les deux côtés
          // dériveraient des clés différentes.
          weWillAnswer: false,
        );
        if (refus != null) {
          TransportTrace.drop(DropKind.handshakeRefused, linkId, refus);
          await _tell(linkId, ByeFrame(refus));
          radio.disconnect(linkId);
          return;
        }
        if (channel.sessionSerial != avantAck) {
          await _sendProfile(linkId, channel);
        }

      case EncryptedFrame():
        final message = await channel.decrypt(frame);
        if (message == null) {
          // Mauvaise clé, compteur rejoué, ou octets modifiés — le canal ne
          // distingue pas, et c'est voulu. Le compteur de trame, lui, permet
          // de trancher après coup entre un rejeu et une divergence de clé.
          TransportTrace.drop(
            DropKind.decryptRefused,
            linkId,
            'compteur ${frame.counter}, canal ${channel.stage.name}',
          );
          return;
        }
        await _onMessage(linkId, channel, message);

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
    // ⚠️ La session, pas la présence. Voir [_identities].
    final snapshot = _identities[linkId];
    // Tout le reste exige de savoir À QUI on parle. Un message reçu avant le
    // profil est ignoré : sans identité, on ne saurait ni l'afficher, ni le
    // ranger, ni décider s'il a le droit d'exister.
    if (snapshot == null) {
      TransportTrace.drop(
        DropKind.beforeProfile,
        linkId,
        '${message.runtimeType}, profil pas encore reçu',
      );
      return;
    }
    TransportTrace.noteDelivered();
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
      // ⚠️ **Un refus d'identité doit laisser une trace CHEZ NOUS.** Seul le
      // pair recevait le `bye` : côté journal, une tentative d'usurpation et
      // un pair parti se ressemblaient exactement.
      TransportTrace.drop(
        DropKind.profileRefused,
        linkId,
        signatureOk
            ? 'clé différente de la poignée de main'
            : 'signature invalide',
      );
      await _tell(linkId, const ByeFrame('profil non authentifié'));
      radio.disconnect(linkId);
      return;
    }
    if (profile.userId == myUserId) {
      // Notre propre annonce, renvoyée par un relais : rien à en faire. Le
      // compter dit si ça arrive vraiment sur le terrain — personne ne le
      // savait.
      TransportTrace.drop(DropKind.ownProfile, linkId);
      radio.disconnect(linkId);
      return;
    }

    final snapshot = profile.toSnapshot();
    _identities[linkId] = snapshot;
    presence.markIdentified(linkId, snapshot);
    _emit(PeerIdentified(linkId, snapshot));
    _emit(const PresenceChanged());
  }

  /// Les canaux sur lesquels notre profil est **déjà parti**.
  ///
  /// ⚠️ **Notre profil doit être la PREMIÈRE trame applicative d'une session.**
  ///
  /// Relevé sur l'appareil de Jay le 2026-08-17 :
  /// `message reçu avant le profil (CertOfferMessage, présence identifying)`.
  /// Le certificat de croisement était parti avant notre profil ; en face, on ne
  /// savait pas encore qui parlait, et il a été **jeté**. Pire : `_certified`
  /// était déjà marqué, donc **aucune nouvelle tentative** — le croisement était
  /// perdu pour de bon, en silence, alors que c'est la fondation des streaks.
  ///
  /// La cause est une course : le balayage des certificats tourne toutes les
  /// 2 s et n'attend que « canal établi », alors que l'identité arrive **après**
  /// la poignée de main. On ne peut pas régler ça en face — c'est l'ordre
  /// d'émission qui décide. D'où l'invariant, tenu ici, à l'émission.
  final _profileSent = <String>{};

  Future<void> _sendProfile(String linkId, SecureChannel channel) async {
    final me = await myProfile();
    final signature = await _identity.sign(
      ProfileMessage.signedPayload(me.userId, me.username),
    );
    _profileSent.add(linkId);
    await _sendWire(
      linkId,
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
    // Notre profil d'abord, **toujours**. Sans lui, le destinataire ne sait pas
    // de qui vient ce message et le jette sans un mot — voir [_profileSent].
    if (!_profileSent.contains(linkId)) await _sendProfile(linkId, channel);
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

  /// Ferme le transport des adresses que la présence vient d'abandonner.
  ///
  /// ⚠️ **Appelé DANS LE MÊME GESTE que l'observation, pas au battement.**
  ///
  /// La fusion d'adresses retire l'entrée de présence tout de suite ; la
  /// fermeture du lien, elle, attendait le battement suivant — jusqu'à **3
  /// secondes**. Pendant cette fenêtre, l'adresse abandonnée n'avait plus
  /// d'identité mais gardait un canal parfaitement vivant : tout message qui y
  /// arrivait était jeté, et le pair d'en face n'en savait rien.
  ///
  /// C'est le second versant du défaut relevé le 2026-08-17. Le premier
  /// (l'identité rangée avec la session) rend la perte impossible ; celui-ci
  /// supprime la fenêtre — et surtout **prévient le pair**, qui parlait
  /// jusque-là dans le vide.
  void _closeMergedAway() {
    for (final address in presence.takeMergedAway()) {
      if (_channels[address]?.stage == ChannelStage.established) {
        TransportTrace.drop(
          DropKind.sessionDropped,
          address,
          "fusion d'adresses",
        );
      }
      _links.remove(address)?.close();
      _channels.remove(address)?.close();
      _identities.remove(address);
      _profileSent.remove(address);
      _awaiting.remove(address);
      radio.disconnect(address);
    }
  }

  /// Battement régulier : rotation de l'index, pairs partis, replis en attente.
  Future<void> tick() async {
    final slot = ProximityIdentity.slotIndex(_clock());
    if (slot != _slot) await refreshFriends();

    // ⚠️ **Les adresses abandonnées par une fusion.**
    //
    // Quand Android renouvelle sa MAC, la présence fusionne les deux lignes du
    // même pair. Mais le LIEN, lui, restait ouvert sur l'adresse abandonnée :
    // `sendToUser` visait alors la nouvelle adresse, qui n'avait aucun canal,
    // et rouvrait une connexion là où une session vivante existait déjà.
    for (final address in presence.takeMergedAway()) {
      if (_channels[address]?.stage == ChannelStage.established) {
        TransportTrace.drop(
          DropKind.sessionDropped,
          address,
          'fusion d\'adresses',
        );
      }
      _links.remove(address)?.close();
      _channels.remove(address)?.close();
      _awaiting.remove(address);
      radio.disconnect(address);
    }

    final gone = presence.prune();
    for (final peer in gone) {
      // ⚠️ Ne devrait plus JAMAIS porter un canal établi : `prune` refuse
      // désormais de faire partir un pair relié. Si ce motif apparaît dans un
      // rapport, c'est que la garde a été contournée — et le compteur le dira
      // avant que Jay n'ait à le remarquer à l'usage.
      if (_channels[peer.address]?.stage == ChannelStage.established) {
        TransportTrace.drop(
          DropKind.sessionDropped,
          peer.address,
          'pair non entendu, canal pourtant établi',
        );
      }
      _links.remove(peer.address)?.close();
      _channels.remove(peer.address)?.close();
      _awaiting.remove(peer.address);
      // ⚠️ **On coupe AUSSI côté radio, et c'est le correctif d'un état
      // collant.** Sans ça, le natif gardait une connexion GATT dont le Dart
      // avait oublié l'existence. La suite était sans issue : `connect()` rend
      // un succès **immédiat** quand un lien existe déjà — sans émettre le
      // moindre événement — donc aucun canal ne pouvait plus être reconstruit
      // avec ce pair, jusqu'à ce que la radio lâche d'elle-même.
      //
      // La règle : *le Dart n'oublie jamais un lien que le natif tient encore.*
      radio.disconnect(peer.address);
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
