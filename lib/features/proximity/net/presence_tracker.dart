import '../../../core/models/nearby_user.dart';
import '../ping_store.dart';
import 'distance_estimate.dart';

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
    this.txPower = 127,
    this.band = ProximityBand.room,
    this.trend = ProximityTrend.stable,
    this.trendAnchorRssi,
    this.trendAnchorAt,
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

  /// Puissance d'émission annoncée par le pair (127 = non annoncée).
  final int txPower;

  /// La bande courante. Gardée pour l'hystérésis : sans elle, on ne saurait
  /// pas de quel côté du seuil on arrive.
  final ProximityBand band;
  final ProximityTrend trend;

  /// Le point de comparaison de la tendance, et son instant.
  ///
  /// ⚠️ Une pente se mesure sur une FENÊTRE, jamais entre deux mesures
  /// consécutives : à 10 mesures par seconde, deux valeurs voisines ne
  /// contiennent que du bruit.
  final double? trendAnchorRssi;
  final DateTime? trendAnchorAt;

  /// Ce qu'on peut honnêtement dire de la distance.
  DistanceEstimate get distance => DistanceModel.estimate(
    smoothedRssi: rssi,
    txPower: txPower,
    currentBand: band,
    trend: trend,
  );

  String? get userId => snapshot?.userId;

  PresencePeer copyWith({
    PresenceStage? stage,
    double? rssi,
    ProximityLevel? level,
    DateTime? lastSeen,
    PingPeerSnapshot? snapshot,
    bool? isFriend,
    int? txPower,
    ProximityBand? band,
    ProximityTrend? trend,
    double? trendAnchorRssi,
    DateTime? trendAnchorAt,
  }) => PresencePeer(
    address: address,
    stage: stage ?? this.stage,
    rssi: rssi ?? this.rssi,
    level: level ?? this.level,
    firstSeen: firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
    snapshot: snapshot ?? this.snapshot,
    isFriend: isFriend ?? this.isFriend,
    txPower: txPower ?? this.txPower,
    band: band ?? this.band,
    trend: trend ?? this.trend,
    trendAnchorRssi: trendAnchorRssi ?? this.trendAnchorRssi,
    trendAnchorAt: trendAnchorAt ?? this.trendAnchorAt,
  );
}

/// La source de vérité de « qui est autour ».
///
/// Classe **pure** : aucune radio, aucun réseau, aucun Riverpod. On lui donne
/// des observations, elle rend un état. C'est ce qui la rend testable
/// exhaustivement — et le lissage comme l'hystérésis sont exactement le genre de
/// règles qu'on ne peut pas valider à la main sur un téléphone.
class PresenceTracker {
  PresenceTracker({DateTime Function()? clock, this.hasLiveLink})
    : _now = clock ?? DateTime.now;

  /// Le transport a-t-il un lien vivant sur cette adresse ?
  ///
  /// Injecté par le réseau. La présence ne connaît pas les liens — elle
  /// **demande**, ce qui lui évite de dépendre de la couche du dessous.
  final bool Function(String address)? hasLiveLink;

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
  /// Fenêtre sur laquelle la pente est mesurée.
  ///
  /// Assez longue pour que le bruit s'annule, assez courte pour qu'un pas de
  /// marche s'y voie. Trois secondes correspondent à ~2 m de marche normale.
  static const trendWindow = Duration(seconds: 3);

  void observe(
    String address,
    int rssi, {
    PingPeerSnapshot? friend,
    int txPower = 127,
  }) {
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
        txPower: txPower,
        band: DistanceModel.bandFor(rssi.toDouble(), null),
        trendAnchorRssi: rssi.toDouble(),
        trendAnchorAt: now,
      );
      if (friend != null) _mergeDuplicates(address);
      return;
    }

    final smoothed = existing.rssi + (rssi - existing.rssi) * smoothing;

    // La tendance se mesure sur une fenêtre glissante : on ne bouge l'ancre que
    // lorsqu'elle est assez vieille pour que la pente ait un sens.
    var trend = existing.trend;
    var anchorRssi = existing.trendAnchorRssi ?? smoothed;
    var anchorAt = existing.trendAnchorAt ?? now;
    if (now.difference(anchorAt) >= trendWindow) {
      trend = DistanceModel.trendFor(
        anchorRssi,
        smoothed,
        now.difference(anchorAt),
      );
      anchorRssi = smoothed;
      anchorAt = now;
    }

    _peers[address] = existing.copyWith(
      rssi: smoothed,
      level: _levelFor(smoothed, existing.level),
      band: DistanceModel.bandFor(smoothed, existing.band),
      trend: trend,
      trendAnchorRssi: anchorRssi,
      trendAnchorAt: anchorAt,
      txPower: txPower != 127 ? txPower : existing.txPower,
      lastSeen: now,
      // Un ami reconnu en cours de route promeut le pair, jamais l'inverse :
      // une identité acquise ne se reperd pas sur une annonce.
      stage: friend != null ? PresenceStage.identified : existing.stage,
      snapshot: friend ?? existing.snapshot,
      isFriend: friend != null ? true : existing.isFriend,
    );
    // Un ami est reconnu ICI, sans poignée de main : c'est donc ici aussi qu'il
    // faut fusionner ses adresses. Ne le faire que dans `markIdentified`
    // laissait le cas le plus fréquent — celui des amis — dupliqué.
    if (friend != null) _mergeDuplicates(address);
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
    _mergeDuplicates(address);
  }

  /// Une personne, une ligne — quelle que soit son adresse BLE.
  ///
  /// ## Le défaut, constaté par Jay le 2026-08-16
  ///
  /// « J'ai deux fois mimi sur mon téléphone », puis « le deuxième a disparu ».
  /// Les deux moitiés de la phrase décrivent exactement le même mécanisme.
  ///
  /// **Android change périodiquement l'adresse MAC Bluetooth de l'appareil**,
  /// pour empêcher le pistage — c'est la même intention que notre identifiant
  /// rotatif, appliquée une couche plus bas. La présence étant indexée par
  /// adresse, un changement de MAC crée donc une **deuxième ligne pour la même
  /// personne** ; l'ancienne s'éteint ensuite toute seule au bout du délai de
  /// grâce, d'où la disparition observée quelques secondes plus tard.
  ///
  /// ⚠️ **L'adresse reste la bonne clé de TRANSPORT** — c'est elle qui désigne
  /// un lien GATT. Mais elle n'a jamais été une identité. Dès qu'on connaît le
  /// `userId`, c'est lui qui fait foi, et les adresses concurrentes fusionnent
  /// sur la plus récemment vue.
  void _mergeDuplicates(String address) {
    final peer = _peers[address];
    final userId = peer?.userId;
    if (peer == null || userId == null) return;

    for (final other in _peers.values.toList()) {
      if (other.address == address || other.userId != userId) continue;

      // ⚠️ **Une adresse qui porte un lien vivant l'emporte sur une adresse
      // plus récente.**
      //
      // Une connexion GATT déjà établie survit au renouvellement de la MAC :
      // elle est liée au lien, pas à l'adresse annoncée. Préférer aveuglément
      // la plus récente revenait donc à désigner une adresse **sans canal**,
      // alors qu'une session vivante existait sur l'autre — et à rouvrir une
      // connexion pour rien. (Défaut du 2026-08-16 : « poignée de main
      // impossible ».)
      final autreEstVivante = hasLiveLink?.call(other.address) ?? false;
      final celleCiEstVivante = hasLiveLink?.call(address) ?? false;

      final String perdante;
      if (autreEstVivante != celleCiEstVivante) {
        perdante = autreEstVivante ? address : other.address;
      } else {
        perdante = other.lastSeen.isAfter(peer.lastSeen)
            ? address
            : other.address;
      }
      _peers.remove(perdante);
      _mergedAway.add(perdante);
      if (perdante == address) return;
    }
  }

  /// Les adresses abandonnées par une fusion, à fermer côté transport.
  ///
  /// ⚠️ **Vidée à la lecture** : sans ça, la même adresse serait refermée à
  /// chaque battement, et un lien tout juste rouvert sur une adresse recyclée
  /// serait coupé sans raison.
  List<String> takeMergedAway() {
    final out = _mergedAway.toList();
    _mergedAway.clear();
    return out;
  }

  final _mergedAway = <String>{};

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
  ///
  /// ⚠️ **Un pair RELIÉ n'est jamais « parti », même devenu inaudible.**
  ///
  /// Deux instruments mesurent deux choses, et les confondre coûtait des
  /// messages. L'**annonce** BLE est une diffusion non fiable : ne plus
  /// l'entendre pendant 25 s ne prouve rien — téléphone en poche, canal occupé,
  /// écran éteint. La **connexion** GATT, elle, est surveillée par la pile
  /// Bluetooth, qui la déclare morte quand elle l'est, et le dit
  /// ([PeerNetwork._onLinkDown]).
  ///
  /// Sans cette garde, `prune` détruisait ici un canal parfaitement vivant —
  /// et **sans rien couper côté radio**. En face, rien ne changeait : le canal
  /// restait établi, l'envoi réussissait sans erreur, et la trame arrivait sur
  /// un lien devenu sans canal, où elle était jetée en silence. Émetteur
  /// satisfait, destinataire muet : le message fantôme signalé par Jay le
  /// 2026-08-16, reproduit par `test/peer_network_test.dart`.
  ///
  /// La règle s'énonce donc positivement : **c'est la mort du lien qui fait
  /// partir un pair relié**, et l'absence d'annonce qui fait partir les autres.
  /// Aucun pair ne reste indéfiniment : le lien mort rend [hasLiveLink] faux,
  /// et le battement suivant emporte le pair.
  ///
  /// ⚠️ [hasLiveLink] existait déjà — posé le 2026-08-16 pour empêcher la
  /// **fusion** d'adresses d'abandonner une session vivante. La cause n'avait
  /// donc été traitée qu'à une porte de sortie sur deux.
  List<PresencePeer> prune() {
    final now = _now();
    final gone = <PresencePeer>[];
    _peers.removeWhere((_, peer) {
      if (hasLiveLink?.call(peer.address) ?? false) return false;
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

  /// Nombre de pairs, tous états confondus. Sert aux tests et au diagnostic.
  int get length => _peers.length;

  /// Combien sont réellement identifiés — le seul chiffre qu'on peut montrer
  /// comme « X personnes autour de toi ».
  int get identifiedCount =>
      _peers.values.where((p) => p.stage == PresenceStage.identified).length;
}
