import '../ping_store.dart';
import 'distance_estimate.dart';

/// Les règles de présence, **en un seul endroit et en secondes**.
///
/// ## Pourquoi elles sont ici, et pas dispersées
///
/// Avant le 2026-08-18, la question « est-il là ? » avait deux réponses qui
/// pouvaient se contredire indéfiniment : le délai de grâce des annonces (25 s)
/// et la vitalité du lien GATT, qui empêchait purement et simplement l'élagage.
/// Cinq causes de « message fantôme » sont sorties de ce désaccord — chacune
/// corrigée par un garde-fou qui a fabriqué la suivante.
///
/// Il n'y a donc plus qu'**une** définition, [freshFor], et tout ce qui est
/// visible ou irréversible s'y adosse : affichage, constat de croisement,
/// barrière du produit.
class PresenceRules {
  /// « Il est là **maintenant**. »
  ///
  /// Décision de Jay (2026-08-18) : plus rien pendant 5 s = parti. Tenable, car
  /// l'advertising tourne à ~100 ms : cinq secondes de silence, c'est une
  /// cinquantaine d'annonces manquées d'affilée.
  static const freshFor = Duration(seconds: 5);

  /// Contact continu exigé avant de **constater un croisement**.
  ///
  /// ⚠️ C'est l'intention de Jay derrière « 15 pings en 20 secondes » : ne pas
  /// compter comme une rencontre les gens qu'on croise et les voitures qui
  /// passent. La mesure, elle, est une **durée** et non un compte :
  /// l'advertising BLE n'est pas cadencé à la seconde mais à ~100 ms, donc
  /// « 15 annonces » est atteint en moins de deux secondes et ne filtre rien.
  ///
  /// ⚠️ **Elle gardait un second usage jusqu'au 2026-08-27** : le seuil
  /// d'ouverture d'un lien GATT vers un inconnu. Ce chemin n'existe plus, et
  /// avec lui la seule raison qu'avait ce seuil de servir à deux choses. Il ne
  /// répond plus qu'à une question — « est-ce un passant ? ».
  static const stableAfter = Duration(seconds: 10);

  /// Au-delà, la session est **oubliée**.
  ///
  /// ⚠️ **Distinct de [freshFor], et ce n'est pas un second délai de grâce.**
  /// Cesser de dire « il est là » et jeter ce qu'on a appris d'un pair sont
  /// deux décisions différentes : la première est une réponse à l'utilisateur,
  /// la seconde efface la durée de contact continu, donc le seuil anti-passant.
  ///
  /// Un pair non frais n'est **ni affiché, ni joignable** : il n'existe plus
  /// pour le produit dès [freshFor]. Ces 25 secondes supplémentaires ne servent
  /// qu'à absorber un trou de radio sans faire repartir [firstHeard] de zéro.
  static const forgetAfter = Duration(seconds: 30);

  /// Nombre minimal d'observations avant de considérer un contact continu.
  ///
  /// Garde contre le cas dégénéré « entendu deux fois, à dix secondes
  /// d'intervalle » : la durée seule le laisserait passer.
  static const minSightings = 5;

  /// Poids de la dernière mesure dans la moyenne mobile du RSSI.
  ///
  /// Le RSSI d'un appareil immobile varie couramment de 10 dB d'une seconde à
  /// l'autre. Sans lissage, l'étiquette de distance clignoterait.
  static const smoothing = 0.35;

  // ⚠️ **`enterVeryClose` / `leaveVeryClose` ont été RETIRÉS le 2026-08-28**,
  // avec `ProximityLevel`. C'était un **second modèle de distance**, avec ses
  // propres seuils (−58 / −66) et sa propre hystérésis, à côté de
  // `ProximityBand` (−55 / −70 / −85, hystérésis 6 dB). Deux modèles pour une
  // même question finissent toujours par se contredire — et celui-ci n'était
  // affiché nulle part.

  /// Une pente se mesure sur une fenêtre, jamais entre deux mesures voisines.
  static const trendWindow = Duration(seconds: 3);
}

/// Où en est un pair, du point de vue de l'interface.
///
/// ⚠️ **Dérivé, jamais stocké.** Le stade était un champ que trois chemins
/// devaient penser à écrire — et l'un d'eux l'oubliait toujours. Il se calcule
/// depuis ce que la session possède réellement.
///
/// ⚠️ **`identifying` a été RETIRÉ le 2026-08-27, avec le transport BLE.**
///
/// Il voulait dire « poignée de main GATT en cours ». Plus aucun lien ne
/// s'ouvre : une identité vient soit du jeton d'ami, reconnu à l'annonce, soit
/// du serveur (`ping_nearby`). Il n'y a plus d'état intermédiaire à afficher,
/// et un stade qui ne peut plus être atteint n'est pas une nuance, c'est du
/// bruit dans un `switch`.
enum PresenceStage {
  /// Vu par la radio. On ne sait pas qui c'est.
  detected,

  /// Identité connue — ami reconnu à son ID rotatif.
  identified,
}

/// Ce que l'interface voit d'un pair.
///
/// **Projection en lecture seule d'une [PeerSession]** : aucun état ne vit ici,
/// et rien ne peut donc diverger de la session. Il n'y a volontairement pas de
/// champ `isFriend` — la présence dit OÙ et À QUELLE DISTANCE, jamais QUI est
/// quoi pour nous ; le statut d'ami se dérive du carnet au moment du rendu.
class PresencePeer {
  const PresencePeer({
    required this.address,
    required this.stage,
    required this.rssi,
    required this.firstSeen,
    required this.lastSeen,
    required this.band,
    required this.trend,
    this.snapshot,
    this.txPower = 127,
  });

  /// Adresse BLE courante. **Clé de transport, jamais une identité.**
  final String address;

  final PresenceStage stage;

  /// RSSI lissé, pas la dernière mesure brute.
  final double rssi;

  final DateTime firstSeen;
  final DateTime lastSeen;
  final ProximityBand band;
  final ProximityTrend trend;
  final PingPeerSnapshot? snapshot;
  final int txPower;

  String? get userId => snapshot?.userId;

  DistanceEstimate get distance => DistanceModel.estimate(
    smoothedRssi: rssi,
    txPower: txPower,
    currentBand: band,
    trend: trend,
  );
}

/// Tout ce que l'on sait et tout ce que l'on tient pour **un** pair.
///
/// ## Pourquoi cet objet existe
///
/// Le réseau tenait neuf collections indexées par adresse — présence, liens,
/// canaux, identités, connexions en cours, replis armés, profils envoyés,
/// croisements certifiés, plus le catalogue natif. Chaque défaut du chantier de
/// proximité était le même : *la collection X a été nettoyée, la Y non*.
///
/// Ici, un pair est **un objet**.
///
/// ⚠️ **Le transport a été retiré le 2026-08-27** : plus de lien, plus de
/// canal, plus de `release()`. Ce qui restait à fermer « en un seul geste »
/// n'existe plus du tout — la cause est supprimée, pas gardée sous surveillance.
/// Une session n'est plus qu'une **observation**, et c'est tout ce qu'elle a
/// jamais eu à être.
///
/// ## L'adresse n'est pas l'identité
///
/// Android renouvelle son adresse MAC à chaque redémarrage d'annonce. Une
/// session porte donc **plusieurs adresses**, et c'est le **jeton** qui les
/// regroupe — voir [PeerRegistry.observe].
class PeerSession {
  PeerSession({
    required String address,
    required DateTime now,
    required int rssi,
    this.txPower = 127,
  }) : addresses = <String>{address},
       _advertAddress = address,
       firstHeard = now,
       lastHeard = now,
       rssi = rssi.toDouble(),
       band = DistanceModel.bandFor(rssi.toDouble(), null),
       _trendAnchorRssi = rssi.toDouble(),
       _trendAnchorAt = now;

  // --------------------------------------------------------------- identité
  /// Toutes les adresses BLE connues de ce pair.
  final Set<String> addresses;

  /// Tous les jetons d'annonce entendus de ce pair, en hexadécimal.
  ///
  /// ⚠️ **C'est la clé de regroupement la plus fiable dont on dispose**, et
  /// elle est bien meilleure que l'adresse : un jeton vaut pour tout un créneau
  /// de 15 minutes, là où Android tire une nouvelle adresse aléatoire **à
  /// chaque redemarrage d'annonce** — soit toutes les 400 ms chez nous
  /// (`ProximityService.cycleMillis`). Voir [PeerRegistry.observe].
  final Set<String> tokens = <String>{};

  String _advertAddress;

  // ⚠️ **`advertAddress` a été RETIRÉ le 2026-08-28** : c'était un second
  // accesseur public rendant exactement le même champ que `address`, et il
  // n'avait aucun lecteur. Deux noms pour une valeur, c'est deux façons de la
  // désigner qui finiront par ne plus vouloir dire la même chose.

  /// L'adresse qui désigne ce pair dans l'interface.
  ///
  /// ⚠️ **C'était `linkAddress ?? _advertAddress` jusqu'au 2026-08-27**, parce
  /// qu'une connexion GATT survivait au renouvellement de la MAC et devait
  /// donc l'emporter. Sans transport, il n'y a plus qu'une adresse possible.
  String get address => _advertAddress;

  /// Profil signé du pair, une fois son identité établie.
  PingPeerSnapshot? snapshot;

  String? get userId => snapshot?.userId;

  // ------------------------------------------------------------ observation
  final DateTime firstHeard;

  /// Dernière **preuve d'observation** : une annonce, ou une trame reçue.
  ///
  /// ⚠️ **Les deux comptent, et c'est ce qui rend [PresenceRules.freshFor]
  /// tenable.** Une trame reçue prouve la présence au moins autant qu'une
  /// annonce — refuser de la compter obligerait à un second délai de grâce pour
  /// ne pas couper une conversation en cours, et l'on aurait de nouveau deux
  /// horloges qui se contredisent.
  DateTime lastHeard;

  int sightings = 1;
  double rssi;
  int txPower;
  ProximityBand band;
  ProximityTrend trend = ProximityTrend.stable;

  double _trendAnchorRssi;
  DateTime _trendAnchorAt;

  // ------------------------------------------------------------------ états

  /// Dérivé, jamais stocké.
  PresenceStage get stage =>
      snapshot != null ? PresenceStage.identified : PresenceStage.detected;

  /// « Il est là **maintenant** » — la seule réponse, pour tout le monde.
  bool isFresh(DateTime now) =>
      now.difference(lastHeard) <= PresenceRules.freshFor;

  /// Contact continu assez long pour qu'il ne s'agisse pas d'un passant.
  ///
  /// La continuité est garantie par la règle d'oubli : un trou de plus de
  /// [PresenceRules.forgetAfter] détruit la session, donc [firstHeard] repart.
  /// Il n'y a pas de troisième réglage à tenir.
  bool isStable(DateTime now) =>
      now.difference(firstHeard) >= PresenceRules.stableAfter &&
      sightings >= PresenceRules.minSightings;

  /// À oublier : plus rien depuis trop longtemps.
  bool isExpired(DateTime now) =>
      now.difference(lastHeard) > PresenceRules.forgetAfter;

  /// Depuis combien de temps ce pair est en contact continu.
  ///
  /// ⚠️ **Point d'observation de test : aucun appelant dans `lib/`.** Vérifié à
  /// l'audit du 2026-08-18 (point E), toujours vrai aux inventaires du
  /// 2026-08-27 et du 2026-08-30. **À retirer avant la mise en production** (`RAPPELS.md`).
  Duration contactDuration(DateTime now) => now.difference(firstHeard);

  // ------------------------------------------------------------- mise à jour

  /// Une annonce BLE vient d'arriver.
  void noteAdvert(String address, int rssi, int txPower, DateTime now) {
    addresses.add(address);
    _advertAddress = address;
    sightings++;
    lastHeard = now;
    if (txPower != 127) this.txPower = txPower;

    this.rssi = this.rssi + (rssi - this.rssi) * PresenceRules.smoothing;
    band = DistanceModel.bandFor(this.rssi, band);

    // La pente se mesure sur une fenêtre glissante : on ne déplace l'ancre que
    // lorsqu'elle est assez vieille pour que la pente ait un sens.
    if (now.difference(_trendAnchorAt) >= PresenceRules.trendWindow) {
      trend = DistanceModel.trendFor(
        _trendAnchorRssi,
        this.rssi,
        now.difference(_trendAnchorAt),
      );
      _trendAnchorRssi = this.rssi;
      _trendAnchorAt = now;
    }
  }

  /// Absorbe une autre session décrivant la **même personne**.
  ///
  /// Arrive quand Android renouvelle sa MAC : on a d'abord vu deux appareils,
  /// puis leurs identités se révèlent identiques. On garde l'observation la
  /// plus riche.
  void absorb(PeerSession other) {
    addresses.addAll(other.addresses);
    tokens.addAll(other.tokens);
    sightings += other.sightings;
    if (other.lastHeard.isAfter(lastHeard)) {
      lastHeard = other.lastHeard;
      _advertAddress = other._advertAddress;
      rssi = other.rssi;
      band = other.band;
      trend = other.trend;
      txPower = other.txPower;
    }
    snapshot ??= other.snapshot;
  }

  PresencePeer toPresence() => PresencePeer(
    address: _advertAddress,
    stage: stage,
    rssi: rssi,
    firstSeen: firstHeard,
    lastSeen: lastHeard,
    band: band,
    trend: trend,
    snapshot: snapshot,
    txPower: txPower,
  );
}

/// Le registre des pairs : **une seule carte, un seul propriétaire**.
///
/// Classe pure — aucune radio, aucun réseau, aucun Riverpod — donc testable
/// exhaustivement.
class PeerRegistry {
  PeerRegistry({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  /// Plusieurs adresses peuvent pointer vers **la même** session.
  final _byAddress = <String, PeerSession>{};

  /// Plusieurs jetons peuvent pointer vers **la même** session.
  ///
  /// ⚠️ **L'index qui manquait, et qui rendait le produit inopérant.** Voir
  /// [observe].
  final _byToken = <String, PeerSession>{};

  final _sessions = <PeerSession>{};

  Iterable<PeerSession> get sessions => _sessions;
  int get length => _sessions.length;

  /// ⚠️ **Point d'observation de test : aucun appelant dans `lib/` depuis le
  /// 2026-08-27.** Il en avait six, tous dans le transport BLE (trame reçue,
  /// lien qui tombe, envoi, contre-signature). Conservé parce que l'index par
  /// adresse existe de toute façon et que les tests du registre s'y adossent —
  /// **à retirer avant la mise en production** (`RAPPELS.md`).
  PeerSession? byAddress(String address) => _byAddress[address];

  PeerSession? byUser(String userId) {
    for (final s in _sessions) {
      if (s.userId == userId) return s;
    }
    return null;
  }

  /// Ce que l'interface a le droit de voir : **les pairs présents maintenant**.
  ///
  /// ⚠️ Un pair non frais n'est pas affiché, même si sa session vit encore. Le
  /// commentaire du fournisseur de présence promettait déjà que « c'est la
  /// présence vivante qui répond, pas un historique » — le code, lui, tolérait
  /// jusqu'à 25 secondes de souvenir.
  List<PresencePeer> get peers {
    final now = _now();
    final list = _sessions
        .where((s) => s.isFresh(now))
        .map((s) => s.toPresence())
        .toList();
    list.sort((a, b) {
      final byStage = b.stage.index.compareTo(a.stage.index);
      return byStage != 0 ? byStage : b.rssi.compareTo(a.rssi);
    });
    return list;
  }

  /// Combien de pairs sont identifiés à cet instant.
  ///
  /// ⚠️ **Point d'observation de test : aucun appelant dans `lib/`.** Vérifié à
  /// l'audit du 2026-08-18 (point E), toujours vrai aux 2026-08-27
  /// et 2026-08-30. L'écran
  /// compte lui-même à partir de `presenceKeysProvider` — il ne lit pas le
  /// registre. **À retirer avant la mise en production** (`RAPPELS.md`).
  int get identifiedCount =>
      peers.where((p) => p.stage == PresenceStage.identified).length;

  /// Vrai si ce pair est joignable **à cet instant**. Point d'entrée unique de
  /// tout ce qui exige la présence physique — la barrière fondatrice du produit.
  bool isPresent(String userId) {
    final s = byUser(userId);
    return s != null && s.isFresh(_now());
  }

  /// Une annonce vue par la radio. Rend la session concernée.
  ///
  /// ## ⚠️ Le JETON prime sur l'adresse, et ce n'est pas un détail
  ///
  /// Cette méthode n'indexait que par adresse. Or une adresse BLE n'est **pas**
  /// une identité : Android en tire une nouvelle **à chaque redemarrage
  /// d'annonce**, et notre service en redémarre une toutes les 400 ms pour
  /// alterner ses jetons (`ProximityService.cycleMillis`). Un seul appareil
  /// produisait donc une session par adresse — Jay a compté « 6 appareils
  /// détectés », puis « 13 », pour un seul téléphone en face.
  ///
  /// Le second effet était le plus grave, et parfaitement silencieux :
  /// [PeerSession.isStable] exige [PresenceRules.stableAfter] de contact
  /// **continu sur la même session** avant de dépenser une connexion. Aucune
  /// session ne vivant plus de 400 ms, **aucun lien n'était jamais tenté** —
  /// « Vérification chiffrée en cours… » indéfiniment, avec
  /// `clientPaths = serverPaths = 0` au diagnostic.
  ///
  /// Le jeton, lui, vaut pour tout un créneau de 15 minutes. C'est donc lui la
  /// clé de regroupement, et l'adresse redevient ce qu'elle est : une clé de
  /// **transport**, celle par laquelle on ouvre un lien.
  ///
  /// ⚠️ [tokenHex] reste facultatif : un test peut légitimement n'observer que
  /// des adresses.
  PeerSession observe(
    String address,
    int rssi, {
    int txPower = 127,
    String? tokenHex,
  }) {
    final now = _now();
    final existing =
        (tokenHex == null ? null : _byToken[tokenHex]) ?? _byAddress[address];
    if (existing != null) {
      existing.noteAdvert(address, rssi, txPower, now);
      _index(existing, address: address, tokenHex: tokenHex);
      return existing;
    }
    final session = PeerSession(
      address: address,
      now: now,
      rssi: rssi,
      txPower: txPower,
    );
    _sessions.add(session);
    _index(session, address: address, tokenHex: tokenHex);
    return session;
  }

  /// Rattache une adresse et un jeton à une session. **Un seul endroit tient
  /// les deux index** — les tenir séparément, c'est la famille de défauts
  /// « X nettoyé, Y oublié » que ce fichier existe pour supprimer.
  void _index(PeerSession session, {String? address, String? tokenHex}) {
    if (address != null) {
      session.addresses.add(address);
      _byAddress[address] = session;
    }
    if (tokenHex != null) {
      session.tokens.add(tokenHex);
      _byToken[tokenHex] = session;
    }
  }

  // ⚠️ **`touch` a été SUPPRIMÉE le 2026-08-27**, avec le transport BLE. Elle
  // créait une session à partir d'un LIEN entrant, sur une adresse jamais
  // annoncée — le côté qui *recevait* une connexion GATT n'ayant souvent rien
  // entendu. Plus aucun lien ne monte : une session ne peut naître que d'une
  // annonce, ce qui est la seule preuve de présence qui nous reste.

  /// Déclare l'identité d'une session, et **fusionne** si cette personne est
  /// déjà connue sous une autre adresse.
  ///
  /// ## Ce que remplace cette méthode
  ///
  /// Android renouvelle son adresse MAC : la même personne apparaissait donc
  /// deux fois, puis l'ancienne ligne s'éteignait toute seule. La correction
  /// d'alors — retirer l'entrée perdante et *se souvenir* de nettoyer plus
  /// tard — a produit la boucle `takeMergedAway`, dupliquée à deux endroits qui
  /// ont divergé.
  ///
  /// Ici, la fusion est **immédiate et complète**.
  ///
  /// ⚠️ **Elle rendait un couple `(session, merged)` jusqu'au 2026-08-27** : la
  /// session perdante était rendue à l'appelant quand elle tenait encore un
  /// lien GATT, parce que seul le réseau pouvait couper la radio. Sans
  /// transport, une session perdante n'a plus rien à refermer — la fusion se
  /// suffit à elle-même et rend simplement la session vivante.
  PeerSession identify(PeerSession session, PingPeerSnapshot snapshot) {
    session.snapshot = snapshot;
    for (final other in _sessions.toList()) {
      if (identical(other, session)) continue;
      if (other.userId != snapshot.userId) continue;

      // La plus ancienne gagne, pour que la durée de contact continu ne
      // reparte pas de zéro à chaque renouvellement de MAC.
      final gagnante = session.firstHeard.isBefore(other.firstHeard)
          ? session
          : other;
      final perdante = identical(gagnante, session) ? other : session;

      gagnante.absorb(perdante);
      _forget(perdante);
      for (final a in gagnante.addresses) {
        _byAddress[a] = gagnante;
      }
      // Les jetons suivent, sinon la prochaine annonce de la perdante
      // ressusciterait une session que l'on vient de fusionner.
      for (final t in gagnante.tokens) {
        _byToken[t] = gagnante;
      }
      return gagnante;
    }
    return session;
  }

  /// **Retire l'identité d'une session, sans la supprimer.**
  ///
  /// ⚠️ **Le pendant exact d'[identify], et il manquait.** Une identité vient
  /// du carnet d'amis ; quand le carnet ne connaît plus la personne, la session
  /// doit redevenir une détection anonyme. Sans ce chemin, l'identité survivait
  /// au retrait de l'ami jusqu'à l'expiration de la session — la radio
  /// continuait de le nommer alors qu'elle n'avait plus le droit de le
  /// reconnaître.
  ///
  /// On ne supprime PAS la session : elle est toujours entendue, et
  /// l'observation reste vraie. C'est le nom qui n'est plus à nous.
  void deidentify(PeerSession session) => session.snapshot = null;

  /// Les sessions à oublier : plus rien entendu depuis [PresenceRules.forgetAfter].
  List<PeerSession> expired() {
    final now = _now();
    return _sessions.where((s) => s.isExpired(now)).toList();
  }

  /// Retire une session du registre.
  void _forget(PeerSession session) {
    _sessions.remove(session);
    _byAddress.removeWhere((_, s) => identical(s, session));
    _byToken.removeWhere((_, s) => identical(s, session));
  }

  void remove(PeerSession session) => _forget(session);

  /// La radio s'est arrêtée : plus rien n'est vrai.
  ///
  /// Rend les sessions abandonnées — l'appelant n'a plus qu'à en informer
  /// l'interface. (Il devait aussi couper leur transport jusqu'au 2026-08-27.)
  List<PeerSession> drain() {
    final all = _sessions.toList();
    _sessions.clear();
    _byAddress.clear();
    _byToken.clear();
    return all;
  }
}
