import 'dart:convert';

import '../proximity_identity.dart';
import 'dart:typed_data';

import '../ping_store.dart';

/// Le format du fil, en un seul endroit.
///
/// ## Pourquoi des types, et pas des `Map<String, dynamic>`
///
/// L'ancienne couche manipulait des maps nues : `inner['sigFrom'] as String`,
/// répété dans huit méthodes. Un champ renommé d'un côté ne se voyait ni à la
/// compilation, ni à l'analyse — seulement à l'exécution, chez Jay, sous la
/// forme d'un pair qui « ne répond pas ». Ici, le format est **déclaré une
/// fois**, encodé et décodé au même endroit, et testé par aller-retour.
///
/// ## La version
///
/// Chaque trame de poignée de main porte [protocolVersion]. Deux appareils qui
/// ne parlent pas la même version se le disent **au premier échange**, au lieu
/// de se donner rendez-vous dans un décodage qui échouera trois trames plus
/// loin sans que personne ne sache pourquoi.
///
/// ⚠️ **Aucune compatibilité avec l'ancien format n'est assurée, et c'est
/// délibéré** : il n'existe que deux appareils de développement et aucune
/// production. Payer une compatibilité que personne n'utilise aurait figé les
/// défauts qu'on est en train de corriger.
const protocolVersion = 2;

/// Trame de transport — ce qui circule vraiment sur le lien.
sealed class WireFrame {
  const WireFrame();

  Map<String, dynamic> toJson();

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Rend `null` si les octets ne sont pas une trame lisible. **Jamais
  /// d'exception** : un pair incompatible ou un octet corrompu est un événement
  /// normal sur une radio, pas une erreur de programmation.
  static WireFrame? decode(Uint8List bytes) {
    try {
      final map = (jsonDecode(utf8.decode(bytes)) as Map)
          .cast<String, dynamic>();
      switch (map['t']) {
        case 'hello':
          return HelloFrame.fromJson(map);
        case 'helloAck':
          return HelloAckFrame.fromJson(map);
        case 'enc':
          return EncryptedFrame.fromJson(map);
        case 'bye':
          return ByeFrame(map['why'] as String? ?? '');
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

/// Ouverture : clé éphémère **signée par la clé d'appareil**.
///
/// ⚠️ **La signature est l'ajout du 2026-08-16, et elle n'est pas cosmétique.**
/// L'ancienne poignée de main envoyait la clé éphémère **nue**. N'importe quel
/// appareil placé entre les deux pouvait donc établir deux sessions et relayer :
/// il voyait tout en clair. Le profil échangé ensuite était bien signé, mais sa
/// signature ne couvrait **que** `userId|username` — pas la clé de session. Un
/// homme du milieu n'avait qu'à relayer ce profil tel quel.
///
/// En signant la clé éphémère, la session est **liée à la clé d'appareil** :
/// pour se glisser au milieu, il faudrait la clé privée Ed25519, qui ne quitte
/// jamais le Keystore.
class HelloFrame extends WireFrame {
  const HelloFrame({
    required this.version,
    required this.ephemeralPublicKey,
    required this.devicePublicKey,
    required this.signature,
  });

  final int version;
  final Uint8List ephemeralPublicKey;
  final Uint8List devicePublicKey;

  /// Signature Ed25519 de [signedPayload].
  final Uint8List signature;

  /// Ce qui est signé : la version et la clé éphémère. **Rien d'autre.**
  ///
  /// ⚠️ **Le RÔLE en faisait partie, et il a été retiré le 2026-08-17.**
  ///
  /// Il valait `'i'` pour l'initiateur, `'r'` pour le répondeur, et servait à
  /// empêcher qu'une trame d'initiateur soit rejouée comme une réponse. Mais le
  /// rôle était déduit de **qui avait composé le numéro** — un fait de
  /// transport, que les deux côtés peuvent lire différemment quand deux liens
  /// se croisent ou qu'une session est reconstruite d'un seul côté. Les deux
  /// pouvaient alors se croire initiateurs : signature refusée, ou pire, clés
  /// identiques mais **préfixes de nonce opposés** — et un message qui
  /// disparaît sans un mot.
  ///
  /// Ce que le rôle protégeait est désormais assuré autrement, et mieux :
  ///
  /// - la **réflexion** (nous renvoyer notre propre clé) est refusée
  ///   explicitement par `SecureChannel.acceptHello` ;
  /// - le **sens** de chaque trame chiffrée vient de l'ordre des deux clés
  ///   éphémères, que les deux côtés calculent à l'identique.
  ///
  /// La règle générale : *ce sur quoi les deux côtés doivent s'accorder ne se
  /// déduit jamais de qui a appelé.*
  static List<int> signedPayload(Uint8List ephemeral) =>
      utf8.encode('nv-hs-v$protocolVersion|${base64Encode(ephemeral)}');

  @override
  Map<String, dynamic> toJson() => {
    't': 'hello',
    'v': version,
    'x': base64Encode(ephemeralPublicKey),
    'ed': base64Encode(devicePublicKey),
    'sig': base64Encode(signature),
  };

  factory HelloFrame.fromJson(Map<String, dynamic> map) => HelloFrame(
    version: map['v'] as int? ?? 1,
    ephemeralPublicKey: base64Decode(map['x'] as String),
    devicePublicKey: base64Decode(map['ed'] as String),
    signature: base64Decode(map['sig'] as String),
  );
}

/// Réponse à [HelloFrame], même contenu et même exigence de signature.
class HelloAckFrame extends WireFrame {
  const HelloAckFrame({
    required this.version,
    required this.ephemeralPublicKey,
    required this.devicePublicKey,
    required this.signature,
  });

  final int version;
  final Uint8List ephemeralPublicKey;
  final Uint8List devicePublicKey;
  final Uint8List signature;

  @override
  Map<String, dynamic> toJson() => {
    't': 'helloAck',
    'v': version,
    'x': base64Encode(ephemeralPublicKey),
    'ed': base64Encode(devicePublicKey),
    'sig': base64Encode(signature),
  };

  factory HelloAckFrame.fromJson(Map<String, dynamic> map) => HelloAckFrame(
    version: map['v'] as int? ?? 1,
    ephemeralPublicKey: base64Decode(map['x'] as String),
    devicePublicKey: base64Decode(map['ed'] as String),
    signature: base64Decode(map['sig'] as String),
  );
}

/// Enveloppe chiffrée. Le **compteur** est en clair : il doit être lisible avant
/// de déchiffrer, puisque c'est lui qui construit le nonce.
class EncryptedFrame extends WireFrame {
  const EncryptedFrame({
    required this.counter,
    required this.cipherText,
    required this.mac,
  });

  /// Numéro de trame dans CE sens. Strictement croissant.
  ///
  /// ⚠️ **C'est la protection contre le rejeu, qui n'existait pas.** Une trame
  /// capturée pouvait être renvoyée telle quelle : elle se déchiffrait
  /// parfaitement, et le message réapparaissait. Sur un chat de proximité, cela
  /// suffisait à faire dire deux fois la même chose à quelqu'un.
  final int counter;

  final Uint8List cipherText;
  final Uint8List mac;

  @override
  Map<String, dynamic> toJson() => {
    't': 'enc',
    'n': counter,
    'c': base64Encode(cipherText),
    'm': base64Encode(mac),
  };

  factory EncryptedFrame.fromJson(Map<String, dynamic> map) => EncryptedFrame(
    counter: map['n'] as int,
    cipherText: base64Decode(map['c'] as String),
    mac: base64Decode(map['m'] as String),
  );
}

/// Fermeture polie : dit **pourquoi** on s'en va.
///
/// Sert surtout au cas « version incompatible », où le silence obligerait le
/// pair à attendre un délai d'expiration pour comprendre.
class ByeFrame extends WireFrame {
  const ByeFrame(this.why);
  final String why;

  @override
  Map<String, dynamic> toJson() => {'t': 'bye', 'why': why};
}

// ---------------------------------------------------------------------------
// Ce qui voyage À L'INTÉRIEUR du tunnel chiffré
// ---------------------------------------------------------------------------

/// Message applicatif. Jamais en clair sur le fil.
sealed class PeerMessage {
  const PeerMessage();

  Map<String, dynamic> toJson();

  static PeerMessage? decode(Map<String, dynamic> map) {
    try {
      switch (map['t']) {
        case 'profile':
          return ProfileMessage.fromJson(map);
        case 'chat':
          return ChatMessage.fromJson(map);
        case 'certOffer':
          return CertOfferMessage.fromJson(map);
        case 'certFinal':
          return CertFinalMessage.fromJson(map);
        case 'friendReq':
          return FriendRequestMessage.fromJson(map);
        case 'friendAccept':
          return FriendAcceptMessage.fromJson(map);
        case 'friendDecline':
          return const FriendDeclineMessage();
        case 'chatRejected':
          return const ChatRejectedMessage();
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

/// Mini-profil, révélation automatique mutuelle (décision A6a de Jay).
class ProfileMessage extends PeerMessage {
  const ProfileMessage({
    required this.userId,
    required this.username,
    this.tagName,
    required this.devicePublicKey,
    required this.signature,
  });

  final String userId;
  final String username;
  final String? tagName;

  /// ⚠️ **Doit être la MÊME clé que celle qui a signé la poignée de main.**
  /// C'est ce qui relie « cette session appartient à cet appareil » à « cet
  /// appareil dit être cet utilisateur ». Sans cette vérification, la signature
  /// de la poignée de main ne prouverait rien d'utile.
  final Uint8List devicePublicKey;
  final Uint8List signature;

  static List<int> signedPayload(String userId, String username) =>
      utf8.encode('nv-profile|$userId|$username');

  PingPeerSnapshot toSnapshot() => PingPeerSnapshot(
    userId: userId,
    username: username,
    tagName: tagName,
    verified: true,
  );

  @override
  Map<String, dynamic> toJson() => {
    't': 'profile',
    'userId': userId,
    'username': username,
    'tagName': tagName,
    'edPub': base64Encode(devicePublicKey),
    'sig': base64Encode(signature),
  };

  factory ProfileMessage.fromJson(Map<String, dynamic> map) => ProfileMessage(
    userId: map['userId'] as String,
    username: map['username'] as String,
    tagName: map['tagName'] as String?,
    devicePublicKey: base64Decode(map['edPub'] as String),
    signature: base64Decode(map['sig'] as String),
  );
}

/// Message de chat ping. Local, TTL 12 h, jamais serveur.
class ChatMessage extends PeerMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.sentAt,
  });

  /// Identifiant d'émission. Permet au destinataire d'ignorer un doublon si la
  /// trame arrive deux fois — le compteur anti-rejeu couvre le fil, celui-ci
  /// couvre un renvoi volontaire après échec.
  final String id;
  final String text;
  final DateTime sentAt;

  @override
  Map<String, dynamic> toJson() => {
    't': 'chat',
    'id': id,
    'text': text,
    'at': sentAt.toUtc().toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> map) => ChatMessage(
    id: map['id'] as String,
    text: map['text'] as String,
    sentAt: DateTime.parse(map['at'] as String).toLocal(),
  );
}

/// Première moitié du certificat de croisement : A signe, B contresignera.
class CertOfferMessage extends PeerMessage {
  const CertOfferMessage({
    required this.a,
    required this.b,
    required this.timestamp,
    required this.signatureA,
    required this.devicePublicKeyA,
  });

  final String a;
  final String b;
  final String timestamp;
  final Uint8List signatureA;
  final Uint8List devicePublicKeyA;

  static List<int> signedPayload(String a, String b, String ts) =>
      utf8.encode('nv-cert|$a|$b|$ts');

  @override
  Map<String, dynamic> toJson() => {
    't': 'certOffer',
    'a': a,
    'b': b,
    'ts': timestamp,
    'sigA': base64Encode(signatureA),
    'edPubA': base64Encode(devicePublicKeyA),
  };

  factory CertOfferMessage.fromJson(Map<String, dynamic> map) =>
      CertOfferMessage(
        a: map['a'] as String,
        b: map['b'] as String,
        timestamp: map['ts'] as String,
        signatureA: base64Decode(map['sigA'] as String),
        devicePublicKeyA: base64Decode(map['edPubA'] as String),
      );
}

/// Certificat complet, co-signé. C'est **cet objet** que le serveur vérifie.
class CertFinalMessage extends PeerMessage {
  const CertFinalMessage(this.certificate);

  /// Gardé sous forme de map : c'est le format attendu par `report_encounter`,
  /// et le retyper ici obligerait à le re-sérialiser à l'identique — une
  /// occasion de divergence pour rien.
  final Map<String, dynamic> certificate;

  @override
  Map<String, dynamic> toJson() => {'t': 'certFinal', ...certificate};

  factory CertFinalMessage.fromJson(Map<String, dynamic> map) {
    final copy = Map<String, dynamic>.from(map)..remove('t');
    return CertFinalMessage(copy);
  }
}

/// Demande d'ami co-signée, envoyée en proximité.
class FriendRequestMessage extends PeerMessage {
  const FriendRequestMessage({
    required this.from,
    required this.to,
    required this.timestamp,
    required this.signature,
    required this.devicePublicKey,
    required this.broadcastKey,
  });

  final String from;
  final String to;
  final String timestamp;
  final Uint8List signature;
  final Uint8List devicePublicKey;

  /// Clé de diffusion de l'émetteur : c'est elle qui permettra de le reconnaître
  /// silencieusement plus tard, sans serveur.
  final Uint8List broadcastKey;

  static List<int> signedPayload(String from, String to, String ts) =>
      utf8.encode('nv-friend|$from|$to|$ts');

  Map<String, dynamic> get record => {
    'from': from,
    'to': to,
    'ts': timestamp,
    'sigFrom': base64Encode(signature),
  };

  @override
  Map<String, dynamic> toJson() => {
    't': 'friendReq',
    'from': from,
    'to': to,
    'ts': timestamp,
    'sigFrom': base64Encode(signature),
    'edPubFrom': base64Encode(devicePublicKey),
    'broadcastFrom': base64Encode(broadcastKey),
  };

  factory FriendRequestMessage.fromJson(Map<String, dynamic> map) =>
      FriendRequestMessage(
        from: map['from'] as String,
        to: map['to'] as String,
        timestamp: map['ts'] as String,
        signature: base64Decode(map['sigFrom'] as String),
        devicePublicKey: base64Decode(map['edPubFrom'] as String),
        broadcastKey: base64Decode(map['broadcastFrom'] as String),
      );
}

/// Acceptation co-signée : c'est ce couple de signatures que le serveur exige.
class FriendAcceptMessage extends PeerMessage {
  const FriendAcceptMessage({
    required this.record,
    required this.devicePublicKey,
    required this.broadcastKey,
  });

  final Map<String, dynamic> record;
  final Uint8List devicePublicKey;
  final Uint8List broadcastKey;

  static List<int> signedPayload(String from, String to, String ts) =>
      utf8.encode('nv-friend-accept|$from|$to|$ts');

  /// Cette acceptation répond-elle vraiment à une demande que **nous** avons
  /// signée ? Rend `null` si oui, sinon le motif du refus.
  ///
  /// ⚠️ **Rien ne le vérifiait avant le 2026-08-17.** Le contrôleur rangeait
  /// l'émetteur dans le carnet d'amis sur la seule foi du message : n'importe
  /// quel pair ayant abouti la poignée de main — donc n'importe qui de
  /// physiquement à côté — pouvait s'inscrire lui-même comme ami.
  ///
  /// Pour une app dont toute la thèse est qu'**être à côté ne suffit pas à être
  /// ami**, c'était la barrière fondatrice qui tombait, localement et en
  /// silence.
  ///
  /// La vérification décisive ne demande **aucun état nouveau** : le record
  /// porte **notre propre signature**, et un tiers ne peut pas la fabriquer.
  /// C'est exactement ce que fait le serveur dans `submit_ble_connection` — on
  /// ne le faisait simplement pas de notre côté.
  Future<String?> refusalFor({
    required String me,
    required String peerUserId,
    required Uint8List myDeviceKey,
  }) async {
    final from = record['from'] as String?;
    final to = record['to'] as String?;
    final ts = record['ts'] as String?;
    final sigFrom = record['sigFrom'] as String?;
    final sigTo = record['sigTo'] as String?;

    if (from == null || to == null || ts == null) return 'record incomplet';
    if (sigFrom == null || sigTo == null) return 'signatures manquantes';
    if (from != me) return 'la demande n\'est pas la nôtre';
    if (to != peerUserId) return 'acceptée par quelqu\'un d\'autre';

    if (!await ProximityIdentity.verify(
      FriendRequestMessage.signedPayload(from, to, ts),
      base64Decode(sigFrom),
      myDeviceKey,
    )) {
      return 'demande jamais émise par nous';
    }
    if (!await ProximityIdentity.verify(
      signedPayload(from, to, ts),
      base64Decode(sigTo),
      devicePublicKey,
    )) {
      return 'signature d\'acceptation invalide';
    }
    return null;
  }

  @override
  Map<String, dynamic> toJson() => {
    't': 'friendAccept',
    ...record,
    'edPubTo': base64Encode(devicePublicKey),
    'broadcastTo': base64Encode(broadcastKey),
  };

  factory FriendAcceptMessage.fromJson(Map<String, dynamic> map) {
    final record = Map<String, dynamic>.from(map)
      ..remove('t')
      ..remove('edPubTo')
      ..remove('broadcastTo');
    return FriendAcceptMessage(
      record: record,
      devicePublicKey: base64Decode(map['edPubTo'] as String),
      broadcastKey: base64Decode(map['broadcastTo'] as String),
    );
  }
}

/// « Ton message a été refusé par ma règle anti-spam. »
///
/// ⚠️ **Existe parce qu'un refus silencieux est pire qu'un refus.** Avant le
/// 2026-08-16, le destinataire jetait le message sans rien dire : l'émetteur le
/// voyait parti, le destinataire ne voyait rien, et les deux se retrouvaient
/// bloqués sans comprendre. Dire non coûte une trame.
class ChatRejectedMessage extends PeerMessage {
  const ChatRejectedMessage();

  @override
  Map<String, dynamic> toJson() => {'t': 'chatRejected'};
}

/// Refus explicite.
///
/// ⚠️ **N'existait pas.** Un refus était purement local : l'émetteur restait sur
/// une demande qui ne recevrait jamais de réponse, sans savoir si elle avait été
/// vue, refusée, ou perdue. Dire non est une information ; la taire est un
/// défaut d'interface, pas une politesse.
class FriendDeclineMessage extends PeerMessage {
  const FriendDeclineMessage();

  @override
  Map<String, dynamic> toJson() => {'t': 'friendDecline'};
}
