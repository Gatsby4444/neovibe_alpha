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
  SecureChannel({
    required this.linkId,
    required this.initiator,
    ProximityIdentity? identity,
  }) : _identity = identity ?? ProximityIdentity();

  final String linkId;

  /// Qui a ouvert le lien. Décide du rôle signé et du préfixe de nonce.
  final bool initiator;

  final ProximityIdentity _identity;

  ChannelStage stage = ChannelStage.fresh;

  SimpleKeyPair? _ephemeral;
  SecretKey? _key;

  /// Clé d'appareil du pair, vérifiée pendant la poignée de main.
  Uint8List? peerDevicePublicKey;

  var _sendCounter = 0;
  var _lastReceivedCounter = -1;

  static final _x = X25519();
  static final _aes = AesGcm.with256bits();

  String get _myRole => initiator ? 'i' : 'r';
  String get _peerRole => initiator ? 'r' : 'i';

  /// Notre trame d'ouverture, signée.
  Future<WireFrame> hello() async {
    _ephemeral ??= await _x.newKeyPair();
    final pub = Uint8List.fromList(
      (await _ephemeral!.extractPublicKey()).bytes,
    );
    final sig = await _identity.sign(HelloFrame.signedPayload(pub, _myRole));
    final ed = await _identity.edPublicKey();
    if (stage == ChannelStage.fresh) stage = ChannelStage.offered;
    return initiator
        ? HelloFrame(
            version: protocolVersion,
            ephemeralPublicKey: pub,
            devicePublicKey: ed,
            signature: sig,
          )
        : HelloAckFrame(
            version: protocolVersion,
            ephemeralPublicKey: pub,
            devicePublicKey: ed,
            signature: sig,
          );
  }

  /// Traite la trame d'ouverture du pair. Rend `null` si tout va bien, sinon le
  /// motif du refus — que l'appelant peut envoyer dans un [ByeFrame].
  ///
  /// ⚠️ **Le refus est explicite et nommé.** L'ancienne couche avalait toute
  /// erreur de poignée de main dans un `catch (_) {}` : un pair incompatible et
  /// un pair malveillant produisaient le même silence.
  Future<String?> acceptHello({
    required int version,
    required Uint8List peerEphemeral,
    required Uint8List peerDeviceKey,
    required Uint8List signature,
  }) async {
    if (stage == ChannelStage.closed) return 'canal fermé';
    if (version != protocolVersion) {
      stage = ChannelStage.closed;
      return 'version $version incompatible (attendu $protocolVersion)';
    }

    final ok = await ProximityIdentity.verify(
      HelloFrame.signedPayload(peerEphemeral, _peerRole),
      signature,
      peerDeviceKey,
    );
    if (!ok) {
      stage = ChannelStage.closed;
      return 'signature de poignée de main invalide';
    }

    _ephemeral ??= await _x.newKeyPair();
    final shared = await _x.sharedSecretKey(
      keyPair: _ephemeral!,
      remotePublicKey: SimplePublicKey(peerEphemeral, type: KeyPairType.x25519),
    );

    // Le SEL lie la clé aux deux éphémères de CETTE session. Trié, pour que les
    // deux côtés dérivent la même chose sans se concerter sur l'ordre.
    final mine = Uint8List.fromList(
      (await _ephemeral!.extractPublicKey()).bytes,
    );
    final pair = [base64Encode(mine), base64Encode(peerEphemeral)]..sort();

    _key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode(pair.join('|')),
      info: utf8.encode('nv-ping-session-v$protocolVersion'),
    );
    peerDevicePublicKey = peerDeviceKey;
    stage = ChannelStage.established;
    return null;
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
  Uint8List _nonce(int counter, {required bool outgoing}) {
    final nonce = Uint8List(12);
    final view = ByteData.sublistView(nonce);
    final fromInitiator = outgoing ? initiator : !initiator;
    view.setUint32(0, fromInitiator ? 0x4e564931 : 0x4e564932, Endian.big);
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
  }
}
