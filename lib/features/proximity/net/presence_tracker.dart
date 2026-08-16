import 'dart:math' as math;

import '../../../core/models/nearby_user.dart';
import '../ping_store.dart';

/// Ce que l'on sait d'un appareil détecté, à un instant donné.
///
/// ⚠️ **L'état est explicite, et c'est tout le sujet.** L'ancienne couche ne
/// connaissait qu'une liste de pairs *déjà identifiés* : un inconnu détecté mais
/// pas encore révélé n'existait nulle part. L'écran affichait donc « Personne à
/// proximité » pendant que deux téléphones se parlaient — indiscernable, pour
/// l'utilisateur, d'un Bluetooth éteint ou d'une permission manquante (défaut
/// B5 du diagnostic du 2026-08-16).
enum PresenceStage {
  /// Vu par la radio. On ne sait pas qui c'est.
  detected,

  /// Poignée de main en cours — il y a quelqu'un, on cherche qui.
  identifying,

  /// Identité connue : ami reconnu à son ID rotatif, ou inconnu révélé.
  identified,
}

class PresencePeer {
  const PresencePeer({
    required this.address,
    required this.stage,
    required this.rssi,
    required this.level,
    required this.firstSeen,
    required this.lastSeen,
    this.snapshot,
    this.isFriend = false,
  });

  /// Adresse BLE. **La clé de suivi tant qu'on ne connaît pas l'identité.**
  final String address;

  final PresenceStage stage;

  /// RSSI **lissé**, pas la dernière mesure brute.
  final double rssi;

  final ProximityLevel level;
  final DateTime firstSeen;
  final DateTime lastSeen;

  /// Profil, une fois l'identité connue.
  final PingPeerSnapshot? snapshot;
  final bool isFriend;

  String? get userId => snapshot?.userId;

  PresencePeer copyWith({
    PresenceStage? stage,
    double? rssi,
    ProximityLevel? level,
    DateTime? lastSeen,
    PingPeerSnapshot? snapshot,
    bool? isFriend,
  }) => PresencePeer(
    address: address,
    stage: stage ?? this.stage,
    rssi: rssi ?? this.rssi,
    level: level ?? this.level,
    firstSeen: firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
    snapshot: snapshot ?? this.snapshot,
    isFriend: isFriend ?? this.isFriend,
  );
}

/// La source de vérité de « qui est autour ».
///
/// Classe **pure** : aucune radio, aucun réseau, aucun Riverpod. On lui donne
/// des observations, elle rend un état. C'est ce qui la rend testable
/// exhaustivement — et le lissage comme l'hystérésis sont exactement le genre de
/// règles qu'on ne peut pas valider à la main sur un téléphone.
class PresenceTracker {
  PresenceTracker({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;
  final _peers = <String, PresencePeer>{};

  /// Poids de la dernière mesure dans la moyenne mobile.
  ///
  /// Le RSSI d'un même appareil immobile varie couramment de 10 dB d'une
  /// seconde à l'autre — réflexions, orientation, corps humain. Sans lissage,
  /// l'étiquette « très proche » clignoterait plusieurs fois par seconde.
  static const smoothing = 0.35;

  /// Seuils **asymétriques** : il faut −58 dBm pour DEVENIR « très proche »,
  /// mais on ne le perd qu'en dessous de −66.
  ///
  /// ⚠️ Sans cette marge, un appareil posé pile à la frontière bascule à chaque
  /// mesure. L'hystérésis n'est pas un raffinement : c'est ce qui sépare une
  /// information d'un scintillement.
  static const enterVeryClose = -58;
  static const leaveVeryClose = -66;

  /// Sans nouvelle trame pendant ce délai, le pair est considéré parti.
  ///
  /// Généreux volontairement : une annonce BLE peut être manquée plusieurs fois
  /// de suite sans que personne n'ait bougé (canal occupé, téléphone en poche).
  static const gracePeriod = Duration(seconds: 25);

  List<PresencePeer> get peers {
    final list = _peers.values.toList()
      ..sort((a, b) {
        // Les identifiés d'abord — ce sont les seuls sur lesquels on peut agir.
        final byStage = b.stage.index.compareTo(a.stage.index);
        if (byStage != 0) return byStage;
        return b.rssi.compareTo(a.rssi);
      });
    return list;
  }

  PresencePeer? byAddress(String address) => _peers[address];

  PresencePeer? byUser(String userId) {
    for (final peer in _peers.values) {
      if (peer.userId == userId) return peer;
    }
    return null;
  }

  /// Vrai si ce pair est **actuellement** à portée. Utilisé par tout ce qui
  /// exige la présence physique — c'est la barrière fondatrice du produit, elle
  /// ne doit jamais s'appuyer sur un souvenir.
  bool isInRange(String userId) => byUser(userId) != null;

  /// Une annonce vue par la radio.
  ///
  /// [friend] est non nul quand l'ID rotatif a été reconnu dans le carnet : le
  /// pair est alors identifié **immédiatement**, sans aucun échange — c'est tout
  /// l'intérêt de l'ID rotatif.
  void observe(String address, int rssi, {PingPeerSnapshot? friend}) {
    final now = _now();
    final existing = _peers[address];

    if (existing == null) {
      _peers[address] = PresencePeer(
        address: address,
        stage: friend == null
            ? PresenceStage.detected
            : PresenceStage.identified,
        rssi: rssi.toDouble(),
        level: rssi >= enterVeryClose
            ? ProximityLevel.veryClose
            : ProximityLevel.close,
        firstSeen: now,
        lastSeen: now,
        snapshot: friend,
        isFriend: friend != null,
      );
      return;
    }

    final smoothed = existing.rssi + (rssi - existing.rssi) * smoothing;
    _peers[address] = existing.copyWith(
      rssi: smoothed,
      level: _levelFor(smoothed, existing.level),
      lastSeen: now,
      // Un ami reconnu en cours de route promeut le pair, jamais l'inverse :
      // une identité acquise ne se reperd pas sur une annonce.
      stage: friend != null ? PresenceStage.identified : existing.stage,
      snapshot: friend ?? existing.snapshot,
      isFriend: friend != null ? true : existing.isFriend,
    );
  }

  ProximityLevel _levelFor(double rssi, ProximityLevel current) {
    if (current == ProximityLevel.veryClose) {
      return rssi <= leaveVeryClose
          ? ProximityLevel.close
          : ProximityLevel.veryClose;
    }
    return rssi >= enterVeryClose
        ? ProximityLevel.veryClose
        : ProximityLevel.close;
  }

  /// Un lien s'est ouvert avec [address].
  ///
  /// ⚠️ **Un lien est en soi une preuve de présence**, et il peut arriver AVANT
  /// la première annonce : rien ne garantit l'ordre entre un résultat de scan et
  /// une connexion GATT entrante. Le côté qui *reçoit* la connexion n'a
  /// d'ailleurs souvent rien vu du tout — c'est l'autre qui l'a repéré.
  ///
  /// Sans cette porte d'entrée, la présence n'avait aucune ligne à identifier
  /// quand le profil arrivait, et **la poignée de main aboutissait dans le
  /// vide** : les deux appareils échangeaient correctement, et l'écran du
  /// récepteur restait désespérément vide. Trouvé par
  /// `test/peer_network_test.dart`, jamais par un test de couche isolée.
  void noteLink(String address) {
    if (_peers.containsKey(address)) return;
    final now = _now();
    _peers[address] = PresencePeer(
      address: address,
      stage: PresenceStage.identifying,
      // Aucune mesure : on prend une valeur prudente plutôt que d'inventer une
      // proximité. La première annonce la corrigera.
      rssi: leaveVeryClose.toDouble(),
      level: ProximityLevel.close,
      firstSeen: now,
      lastSeen: now,
    );
  }

  /// La poignée de main démarre : il y a quelqu'un, on ne sait pas encore qui.
  void markIdentifying(String address) {
    noteLink(address);
    final peer = _peers[address]!;
    if (peer.stage == PresenceStage.identified) return;
    _peers[address] = peer.copyWith(stage: PresenceStage.identifying);
  }

  /// La poignée de main a abouti.
  void markIdentified(String address, PingPeerSnapshot snapshot) {
    noteLink(address);
    final peer = _peers[address]!;
    _peers[address] = peer.copyWith(
      stage: PresenceStage.identified,
      snapshot: snapshot,
      lastSeen: _now(),
    );
  }

  /// La poignée de main a échoué : on **retombe sur « détecté »**, pas sur rien.
  ///
  /// ⚠️ Le pair est toujours là — la radio le voit. Le faire disparaître de la
  /// liste dirait « personne à proximité » alors que quelqu'un est bien là, et
  /// c'est précisément le mensonge qu'on supprime partout dans ce chantier.
  void markIdentificationFailed(String address) {
    final peer = _peers[address];
    if (peer == null || peer.stage != PresenceStage.identifying) return;
    _peers[address] = peer.copyWith(stage: PresenceStage.detected);
  }

  /// Retire les pairs qu'on n'a plus vus. Rend ceux qui viennent de partir.
  List<PresencePeer> prune() {
    final now = _now();
    final gone = <PresencePeer>[];
    _peers.removeWhere((_, peer) {
      final stale = now.difference(peer.lastSeen) > gracePeriod;
      if (stale) gone.add(peer);
      return stale;
    });
    return gone;
  }

  /// La radio s'est arrêtée : plus rien n'est vrai.
  ///
  /// ⚠️ **À appeler quand le Bluetooth s'éteint.** Garder la liste donnerait des
  /// pairs « présents » que plus rien ne confirme — un souvenir présenté comme
  /// une observation.
  void clear() => _peers.clear();

  /// Depuis combien de temps ce pair est-il là, sans interruption ?
  ///
  /// C'est la mesure sur laquelle repose le certificat de croisement (10 s de
  /// contact continu, décision de Jay du 2026-07-13).
  Duration contactDuration(String address) {
    final peer = _peers[address];
    if (peer == null) return Duration.zero;
    return _now().difference(peer.firstSeen);
  }

  /// Une distance grossière, **jamais précise** (spec 4.2 : on ne donne pas de
  /// distance en mètres, et on ne le fera pas — ce serait un traqueur).
  static ProximityLevel levelOf(int rssi) =>
      rssi >= enterVeryClose ? ProximityLevel.veryClose : ProximityLevel.close;

  /// Nombre de pairs, tous états confondus. Sert aux tests et au diagnostic.
  int get length => _peers.length;

  /// Combien sont réellement identifiés — le seul chiffre qu'on peut montrer
  /// comme « X personnes autour de toi ».
  int get identifiedCount =>
      _peers.values.where((p) => p.stage == PresenceStage.identified).length;

  /// Le meilleur RSSI observé, pour le diagnostic.
  double get strongest => _peers.values.isEmpty
      ? double.negativeInfinity
      : _peers.values.map((p) => p.rssi).reduce(math.max);
}
