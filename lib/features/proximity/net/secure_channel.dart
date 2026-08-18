import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../proximity_identity.dart';
import 'proximity_protocol.dart';

/// Où en est le canal.
enum ChannelStage {
  /// Créé, rien envoyé.
  fresh,

  /// Notre `hello` est parti, on attend la réponse.
  offered,

  /// Clé dérivée, pair authentifié. On peut chiffrer.
  established,

  /// Terminé — volontairement ou sur échec. Ne redevient jamais actif.
  closed,
}

/// Le canal chiffré avec un pair, et **rien d'autre**.
///
/// Il ne sait pas ce qu'il chiffre, il ne connaît ni profil, ni message, ni
/// certificat. Il ouvre, il chiffre, il déchiffre, il refuse.
///
/// ## Ce qu'il garantit
///
/// 1. **Confidentialité** — X25519 éphémère → HKDF-SHA256 → AES-GCM 256.
/// 2. **Authenticité du pair** — la clé éphémère est **signée** par la clé
///    d'appareil Ed25519. Un homme du milieu devrait posséder une clé privée qui
///    ne quitte jamais le Keystore.
/// 3. **Fraîcheur** — chaque trame porte un compteur strictement croissant. Une
///    trame rejouée est refusée.
///
/// ⚠️ **Les points 2 et 3 sont nouveaux au 2026-08-16.** L'ancienne poignée de
/// main envoyait la clé éphémère nue et n'avait aucun compteur : deux défauts
/// qui ne se voient ni au test fonctionnel ni à l'usage, puisque tout marche
/// parfaitement tant que personne n'attaque.
class SecureChannel {
  /// ⚠️ **[identity] est OBLIGATOIRE.**
  ///
  /// Il valait `identity ?? ProximityIdentity()`, donc **une identité neuve par
  /// canal**, c'est-à-dire par lien. Chacune relisait le Keystore de son côté et
  /// gardait son propre cache — le même défaut que les trois carnets d'amis du
  /// 2026-08-17, appliqué cette fois à la clé qui signe la poignée de main.
  ///
  /// Un défaut commode qui fabrique un état partagé est un défaut qui finira
  /// par diverger : on ferme la porte au lieu de la surveiller.
  SecureChannel({required this.linkId, required ProximityIdentity identity})
    // Le champ est privé : un paramètre formel initialisant l'exposerait sous
    // son nom privé, que les appelants ne peuvent pas nommer.
    // ignore: prefer_initializing_formals
    : _identity = identity;

  final String linkId;

  final ProximityIdentity _identity;

  ChannelStage stage = ChannelStage.fresh;

  SimpleKeyPair? _ephemeral;
  SecretKey? _key;

  /// La clé éphémère du pair — **c'est elle qui identifie la session.**
  ///
  /// ⚠️ Une session n'appartient ni à une adresse, ni à un lien, ni à celui qui
  /// a appelé : elle appartient au **couple de clés éphémères**. C'est la seule
  /// chose que les deux côtés voient à l'identique, et donc la seule sur
  /// laquelle ils peuvent s'accorder sans se concerter.
  Uint8List? _peerEphemeral;

  /// Clé d'appareil du pair, vérifiée pendant la poignée de main.
  Uint8List? peerDevicePublicKey;

  var _sendCounter = 0;
  var _lastReceivedCounter = -1;

  /// Combien de fois la session a été **reconstruite** sur ce canal.
  ///
  /// Consigné au diagnostic : une reconstruction est normale (le pair a perdu
  /// sa session), mais leur nombre dit si le lien est instable.
  var rekeys = 0;

  /// Change à chaque fois qu'une clé de session est dérivée.
  ///
  /// ⚠️ **C'est ce qui distingue « on vient de s'accorder » de « on était déjà
  /// d'accord ».** Les deux côtés s'ouvrant désormais en même temps, chacun
  /// reçoit aussi une réponse à une poignée de main déjà conclue. Sans ce
  /// repère, l'appelant renverrait son profil à chaque trame de service — du
  /// trafic pour rien sur une radio qui n'en a pas de trop.
  var sessionSerial = 0;

  /// Préfixes de nonce, dérivés de l'ORDRE des deux clés éphémères.
  int _myPrefix = 0;
  int _peerPrefix = 0;

  static final _x = X25519();
  static final _aes = AesGcm.with256bits();

  /// Notre trame d'**ouverture**.
  Future<WireFrame> open() async => HelloFrame(
    version: protocolVersion,
    ephemeralPublicKey: await _myEphemeralPublicKey(),
    devicePublicKey: await _identity.edPublicKey(),
    signature: await _identity.sign(
      HelloFrame.signedPayload(await _myEphemeralPublicKey()),
    ),
  );

  /// Notre **réponse** à l'ouverture du pair.
  ///
  /// ⚠️ **Ouverture et réponse ne se distinguent plus par un rôle mémorisé,
  /// mais par le MOMENT.** C'est ce qui termine la poignée de main : celui qui
  /// reçoit une ouverture répond, celui qui reçoit une réponse se tait. Deux
  /// appareils qui s'ouvrent en même temps s'accordent quand même, au lieu de
  /// se renvoyer des ouvertures indéfiniment.
  Future<WireFrame> answer() async => HelloAckFrame(
    version: protocolVersion,
    ephemeralPublicKey: await _myEphemeralPublicKey(),
    devicePublicKey: await _identity.edPublicKey(),
    signature: await _identity.sign(
      HelloFrame.signedPayload(await _myEphemeralPublicKey()),
    ),
  );

  Future<Uint8List> _myEphemeralPublicKey() async {
    final pair = _ephemeral ??= await _x.newKeyPair();
    if (stage == ChannelStage.fresh) stage = ChannelStage.offered;
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  /// Traite la trame d'ouverture du pair. Rend `null` si tout va bien, sinon le
  /// motif du refus — que l'appelant peut envoyer dans un [ByeFrame].
  ///
  /// ⚠️ **Le refus est explicite et nommé.** L'ancienne couche avalait toute
  /// erreur de poignée de main dans un `catch (_) {}` : un pair incompatible et
  /// un pair malveillant produisaient le même silence.
  /// ⚠️ **Un `hello` est une demande de session, et elle l'emporte toujours.**
  ///
  /// C'est le correctif de la quatrième cause de message fantôme (2026-08-17).
  /// Un pair n'envoie un `hello` que lorsqu'il **n'a plus de session** avec
  /// nous : garder la nôtre ne peut alors produire que du silence, puisque la
  /// clé qu'il utilisait, il vient de la jeter.
  ///
  /// Le défaut relevé sur les appareils de Jay : le pair reconstruisait sa
  /// session et repartait au compteur 0 ; nous gardions l'ancien compteur, et
  /// **toutes ses trames étaient refusées** (`déchiffrement refusé, compteur 0
  /// puis 1`). Reconstruire à moitié — la clé mais pas les compteurs — est pire
  /// que ne pas reconstruire du tout : ça marche assez pour ne rien signaler.
  ///
  /// Reconstruire, c'est donc : **nouvelle clé éphémère, nouvelle clé de
  /// session, compteurs remis à zéro.** Tout, ou rien.
  ///
  /// [weWillAnswer] dit si l'appelant va répondre. Il ne renouvelle notre clé
  /// éphémère **que** dans ce cas : sans réponse, le pair ne l'apprendrait
  /// jamais et les deux côtés dériveraient des clés différentes — le défaut
  /// qu'on est en train de corriger, retourné.
  Future<String?> acceptHello({
    required int version,
    required Uint8List peerEphemeral,
    required Uint8List peerDeviceKey,
    required Uint8List signature,
    required bool weWillAnswer,
  }) async {
    if (stage == ChannelStage.closed) return 'canal fermé';
    if (version != protocolVersion) {
      stage = ChannelStage.closed;
      return 'version $version incompatible (attendu $protocolVersion)';
    }

    // La signature d'abord : on ne touche à rien tant que l'origine de cette
    // trame n'est pas prouvée. Une reconstruction est un pouvoir — remettre les
    // compteurs à zéro — et un pouvoir ne s'accorde pas à un inconnu.
    final ok = await ProximityIdentity.verify(
      HelloFrame.signedPayload(peerEphemeral),
      signature,
      peerDeviceKey,
    );
    if (!ok) {
      stage = ChannelStage.closed;
      return 'signature de poignée de main invalide';
    }

    // ⚠️ **Réflexion.** Le rôle signé servait à empêcher qu'on nous renvoie
    // notre propre trame d'ouverture. Il n'existe plus ; la protection est
    // désormais explicite, et elle est plus directe : notre clé éphémère ne
    // peut pas être celle d'en face.
    final actuel = _ephemeral;
    if (actuel != null) {
      final mienne = Uint8List.fromList(
        (await actuel.extractPublicKey()).bytes,
      );
      if (_sameBytes(mienne, peerEphemeral)) return 'clé éphémère réfléchie';
    }

    final connue = _peerEphemeral;
    if (connue != null && _sameBytes(connue, peerEphemeral)) {
      // Même clé éphémère : c'est la même session, pas une nouvelle. Un `hello`
      // répété — retransmission, trames croisées — ne doit **pas** remettre les
      // compteurs à zéro : ce serait ouvrir soi-même la porte au rejeu que le
      // compteur existe pour fermer.
      return null;
    }

    if (connue != null) {
      // Le pair a reconstruit sa session. On repart de zéro **avec** lui.
      //
      // ⚠️ La clé éphémère est renouvelée, et pas seulement les compteurs :
      // sans ça, un `hello` ancien rejoué par un tiers réinstallerait une clé
      // déjà utilisée, et les trames de cette époque redeviendraient
      // déchiffrables. Remettre les compteurs à zéro sans changer de clé, c'est
      // désarmer l'anti-rejeu.
      if (weWillAnswer) _ephemeral = await _x.newKeyPair();
      _sendCounter = 0;
      _lastReceivedCounter = -1;
      rekeys++;
    }

    final mine = await _myEphemeralPublicKey();
    final shared = await _x.sharedSecretKey(
      keyPair: _ephemeral!,
      remotePublicKey: SimplePublicKey(peerEphemeral, type: KeyPairType.x25519),
    );

    // Le SEL lie la clé aux deux éphémères de CETTE session. Trié, pour que les
    // deux côtés dérivent la même chose sans se concerter sur l'ordre.
    final pair = [base64Encode(mine), base64Encode(peerEphemeral)]..sort();

    _key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode(pair.join('|')),
      info: utf8.encode('nv-ping-session-v$protocolVersion'),
    );

    // ⚠️ **Le SENS vient de l'ordre des deux clés, jamais de qui a appelé.**
    //
    // Il venait de `initiator`, c'est-à-dire du fait d'avoir composé le numéro.
    // Deux appareils qui se connectent en même temps, ou une session
    // reconstruite d'un seul côté, pouvaient donc se croire tous les deux
    // initiateurs : mêmes clés, **préfixes de nonce opposés**, et AES-GCM
    // refuse tout — sans un mot.
    //
    // L'ordre des clés éphémères, lui, est le même des deux côtés par
    // construction, et il s'inverse exactement une fois. Il n'y a plus rien à
    // se dire pour être d'accord.
    final jeSuisPremier = base64Encode(mine).compareTo(pair.first) == 0;
    _myPrefix = jeSuisPremier ? 0x4e564931 : 0x4e564932;
    _peerPrefix = jeSuisPremier ? 0x4e564932 : 0x4e564931;

    _peerEphemeral = peerEphemeral;
    peerDevicePublicKey = peerDeviceKey;
    stage = ChannelStage.established;
    sessionSerial++;
    return null;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Vrai si [key] est bien la clé d'appareil qui a signé la poignée de main.
  ///
  /// ⚠️ **C'est ce qui relie la session à une identité.** Sans cette
  /// vérification, un pair pourrait ouvrir un canal authentifié avec sa propre
  /// clé d'appareil, puis présenter le profil signé de quelqu'un d'autre,
  /// capturé ailleurs. La signature du profil prouve *qui l'a écrit*, pas *qui
  /// est en face*.
  bool isPeerDeviceKey(Uint8List key) {
    final mine = peerDevicePublicKey;
    if (mine == null || mine.length != key.length) return false;
    var diff = 0;
    for (var i = 0; i < key.length; i++) {
      diff |= mine[i] ^ key[i];
    }
    return diff == 0;
  }

  /// Nonce de 12 octets : `[préfixe de sens (4)][compteur (8)]`.
  ///
  /// Le préfixe sépare les deux sens, sinon les deux pairs réutiliseraient le
  /// même nonce avec la même clé au même compteur — la faute la plus classique
  /// et la plus destructrice avec AES-GCM.
  ///
  /// Les deux préfixes sont posés à la dérivation de la clé, d'après l'ordre
  /// des clés éphémères. Voir [acceptHello].
  Uint8List _nonce(int counter, {required bool outgoing}) {
    final nonce = Uint8List(12);
    final view = ByteData.sublistView(nonce);
    view.setUint32(0, outgoing ? _myPrefix : _peerPrefix, Endian.big);
    view.setUint64(4, counter, Endian.big);
    return nonce;
  }

  Future<EncryptedFrame> encrypt(PeerMessage message) async {
    final key = _key;
    if (key == null || stage != ChannelStage.established) {
      throw StateError('canal $linkId non établi');
    }
    final counter = _sendCounter++;
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(message.toJson())),
      secretKey: key,
      nonce: _nonce(counter, outgoing: true),
    );
    return EncryptedFrame(
      counter: counter,
      cipherText: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Déchiffre, ou rend `null`.
  ///
  /// Rend `null` dans exactement trois cas, et il n'y en a pas d'autre : canal
  /// non établi, **compteur déjà vu** (rejeu), authentification en échec (octet
  /// modifié ou mauvaise clé).
  Future<PeerMessage?> decrypt(EncryptedFrame frame) async {
    final key = _key;
    if (key == null || stage != ChannelStage.established) return null;

    // Rejeu : on refuse tout compteur qui n'avance pas. Le BLE conserve l'ordre
    // sur un lien donné, donc exiger la stricte croissance ne coûte rien de
    // légitime — et une trame réordonnée serait de toute façon suspecte.
    if (frame.counter <= _lastReceivedCounter) return null;

    try {
      final clear = await _aes.decrypt(
        SecretBox(
          frame.cipherText,
          nonce: _nonce(frame.counter, outgoing: false),
          mac: Mac(frame.mac),
        ),
        secretKey: key,
      );
      final map = (jsonDecode(utf8.decode(clear)) as Map)
          .cast<String, dynamic>();
      // Le compteur n'avance QU'APRÈS succès : une trame forgée ne doit pas
      // pouvoir faire sauter un numéro et faire refuser la vraie trame suivante.
      _lastReceivedCounter = frame.counter;
      return PeerMessage.decode(map);
    } catch (_) {
      return null;
    }
  }

  void close() {
    stage = ChannelStage.closed;
    _key = null;
    _ephemeral = null;
    _peerEphemeral = null;
  }
}
