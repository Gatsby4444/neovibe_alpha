import '../../../core/models/nearby_user.dart';
import '../ping_store.dart';
import 'distance_estimate.dart';
import 'peer_link.dart';
import 'secure_channel.dart';

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
/// visible ou irréversible s'y adosse : affichage, envoi d'un message,
/// certificat de croisement, barrière du produit.
class PresenceRules {
  /// « Il est là **maintenant**. »
  ///
  /// Décision de Jay (2026-08-18) : plus rien pendant 5 s = parti. Tenable, car
  /// l'advertising tourne à ~100 ms : cinq secondes de silence, c'est une
  /// cinquantaine d'annonces manquées d'affilée.
  static const freshFor = Duration(seconds: 5);

  /// Contact continu exigé avant de **dépenser une connexion** pour un inconnu.
  ///
  /// ⚠️ C'est l'intention de Jay derrière « 15 pings en 20 secondes » : ne pas
  /// ouvrir un lien avec les gens qu'on croise et les voitures qui passent.
  /// La mesure, elle, est une **durée** et non un compte : l'advertising BLE
  /// n'est pas cadencé à la seconde mais à ~100 ms, donc « 15 annonces » est
  /// atteint en moins de deux secondes et ne filtre rien.
  ///
  /// Même valeur que le certificat de croisement (décision de Jay du
  /// 2026-07-13) : un seul seuil dit « ce n'est pas un passant », et il sert
  /// aux deux. Un réglage en moins, pas un de plus.
  static const stableAfter = Duration(seconds: 10);

  /// Au-delà, la session est **oubliée** et son transport refermé.
  ///
  /// ⚠️ **Distinct de [freshFor], et ce n'est pas un second délai de grâce.**
  /// Cesser de dire « il est là » et démonter une session chiffrée sont deux
  /// décisions différentes : la première est une réponse à l'utilisateur, la
  /// seconde détruit un état partagé avec le pair. Les confondre, c'est
  /// reconstruire le défaut d'origine — une session démontée d'un seul côté,
  /// et des trames qui arrivent sur un lien sans canal.
  ///
  /// Un pair non frais n'est **ni affiché, ni joignable** : il n'existe plus
  /// pour le produit dès [freshFor]. Ces 25 secondes supplémentaires ne servent
  /// qu'à absorber un trou de radio sans payer une poignée de main complète.
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

  /// Seuils **asymétriques** : −58 dBm pour devenir « très proche », −66 pour
  /// cesser de l'être. Sans cette marge, un appareil posé sur le seuil bascule
  /// à chaque mesure.
  static const enterVeryClose = -58;
  static const leaveVeryClose = -66;

  /// Une pente se mesure sur une fenêtre, jamais entre deux mesures voisines.
  static const trendWindow = Duration(seconds: 3);
}

/// Où en est un pair, du point de vue de l'interface.
///
/// ⚠️ **Dérivé, jamais stocké.** Le stade était un champ que trois chemins
/// devaient penser à écrire — et l'un d'eux l'oubliait toujours. Il se calcule
/// désormais depuis ce que la session possède réellement.
enum PresenceStage {
  /// Vu par la radio. On ne sait pas qui c'est.
  detected,

  /// Poignée de main en cours : il y a quelqu'un, on cherche qui.
  identifying,

  /// Identité connue — ami reconnu à son ID rotatif, ou inconnu révélé.
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
    required this.level,
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

  final ProximityLevel level;
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
/// proximité est le même : *la collection X a été nettoyée, la Y non*. Le canal
/// survivait au lien, l'identité survivait au canal, le natif gardait une
/// connexion que le Dart avait oubliée.
///
/// Ce n'était pas une série de bugs mais **une conception qui en fabriquait un
/// nouveau à chaque correction** — au point que la boucle de nettoyage
/// `takeMergedAway` existait en deux exemplaires dont les corps avaient déjà
/// divergé.
///
/// Ici, un pair est **un objet**. Le fermer est **un geste** ([release]), qu'on
/// ne peut pas faire à moitié.
///
/// ## L'adresse n'est pas l'identité
///
/// Android renouvelle périodiquement son adresse MAC. Une session porte donc
/// **plusieurs adresses** et sait laquelle porte le lien : il n'y a plus
/// d'adresse « abandonnée » à refermer, ni de session sacrifiée par une fusion.
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
       level = rssi >= PresenceRules.enterVeryClose
           ? ProximityLevel.veryClose
           : ProximityLevel.close,
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

  /// La dernière adresse entendue. C'est par elle qu'on ouvre un lien.
  String get advertAddress => _advertAddress;

  /// L'adresse qui porte le lien ouvert, s'il y en a un.
  ///
  /// ⚠️ **Peut différer de [advertAddress]** : une connexion GATT survit au
  /// renouvellement de la MAC, puisqu'elle est liée au lien et non à l'adresse
  /// annoncée. C'est exactement ce que l'ancienne fusion d'adresses cassait.
  String? linkAddress;

  /// L'adresse par laquelle on parle à ce pair : celle du lien s'il existe,
  /// sinon la dernière annoncée. **Un seul endroit décide**, au lieu de laisser
  /// chaque appelant choisir — c'est ce choix dispersé qui faisait viser une
  /// adresse sans canal alors qu'une session vivante existait sur l'autre.
  String get address => linkAddress ?? _advertAddress;

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
  ProximityLevel level;

  double _trendAnchorRssi;
  DateTime _trendAnchorAt;

  // -------------------------------------------------------------- transport
  PeerLink? link;
  SecureChannel? channel;

  /// Une connexion est en cours d'ouverture.
  bool connecting = false;

  /// Notre profil est déjà parti sur cette session.
  bool profileSent = false;

  /// Un certificat de croisement a déjà été proposé.
  bool certified = false;

  // ------------------------------------------------------------------ états

  /// Dérivé, jamais stocké.
  PresenceStage get stage {
    if (snapshot != null) return PresenceStage.identified;
    if (connecting || link != null) return PresenceStage.identifying;
    return PresenceStage.detected;
  }

  bool get hasChannel => channel?.stage == ChannelStage.established;

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
  /// l'audit du 2026-08-18 (point E). La règle d'ouverture de lien, elle, mesure
  /// la durée directement contre [PresenceRules.stableAfter] — elle ne passe pas
  /// par ici. **À retirer avant la mise en production** (`RAPPELS.md`).
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
    level = _levelFor(this.rssi);
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

  /// Une trame est arrivée du pair : c'est une observation, pas un souvenir.
  void noteTraffic(DateTime now) => lastHeard = now;

  ProximityLevel _levelFor(double rssi) {
    if (level == ProximityLevel.veryClose) {
      return rssi <= PresenceRules.leaveVeryClose
          ? ProximityLevel.close
          : ProximityLevel.veryClose;
    }
    return rssi >= PresenceRules.enterVeryClose
        ? ProximityLevel.veryClose
        : ProximityLevel.close;
  }

  /// Absorbe une autre session décrivant la **même personne**.
  ///
  /// Arrive quand Android renouvelle sa MAC : on a d'abord vu deux appareils,
  /// puis leurs identités se révèlent identiques. On garde l'observation la
  /// plus riche et **le lien vivant, d'où qu'il vienne**.
  void absorb(PeerSession other) {
    addresses.addAll(other.addresses);
    tokens.addAll(other.tokens);
    sightings += other.sightings;
    if (other.lastHeard.isAfter(lastHeard)) {
      lastHeard = other.lastHeard;
      _advertAddress = other._advertAddress;
      rssi = other.rssi;
      band = other.band;
      level = other.level;
      trend = other.trend;
      txPower = other.txPower;
    }
    snapshot ??= other.snapshot;
    certified = certified || other.certified;

    // Le lien vivant l'emporte, quel que soit son âge : une session chiffrée
    // négociée coûte une poignée de main, une adresse ne coûte rien.
    if (link == null && other.link != null) {
      link = other.link;
      channel = other.channel;
      linkAddress = other.linkAddress;
      profileSent = other.profileSent;
      other.link = null;
      other.channel = null;
      other.linkAddress = null;
    }
  }

  /// Défait **tout** le transport, en un seul geste.
  ///
  /// ⚠️ C'est la méthode qui rend impossible la famille de défauts « X nettoyé,
  /// Y oublié ». Rien d'autre ne doit fermer un lien ou un canal.
  void release() {
    link?.close();
    link = null;
    channel?.close();
    channel = null;
    linkAddress = null;
    profileSent = false;
    connecting = false;
  }

  PresencePeer toPresence() => PresencePeer(
    address: linkAddress ?? _advertAddress,
    stage: stage,
    rssi: rssi,
    level: level,
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
/// exhaustivement. Elle ne ferme rien elle-même : le transport appartient au
/// réseau, qui seul sait couper côté radio.
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
  /// jusqu'à 25 secondes de souvenir, et l'infini pour un pair relié.
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
  /// l'audit du 2026-08-18 (point E). L'écran compte lui-même à partir de
  /// `view.peers` — il ne lit pas le registre. **À retirer avant la mise en
  /// production** (`RAPPELS.md`).
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
  /// ⚠️ [tokenHex] reste facultatif : un lien peut monter sans qu'aucune
  /// annonce n'ait été entendue (voir [touch]), et un test peut légitimement
  /// n'observer que des adresses.
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

  /// Un lien s'ouvre sur une adresse jamais annoncée.
  ///
  /// ⚠️ **Un lien est en soi une preuve de présence**, et il peut précéder la
  /// première annonce : le côté qui *reçoit* la connexion n'a souvent rien vu
  /// du tout. Sans cette porte d'entrée, la poignée de main aboutissait dans le
  /// vide et l'écran du récepteur restait désespérément vide.
  PeerSession touch(String address) {
    final existing = _byAddress[address];
    if (existing != null) {
      existing.noteTraffic(_now());
      return existing;
    }
    final now = _now();
    final session = PeerSession(
      address: address,
      now: now,
      // Aucune mesure : on prend une valeur prudente plutôt que d'inventer une
      // proximité. La première annonce la corrigera.
      rssi: PresenceRules.leaveVeryClose,
    );
    _sessions.add(session);
    _index(session, address: address);
    return session;
  }

  /// Déclare l'identité d'une session, et **fusionne** si cette personne est
  /// déjà connue sous une autre adresse.
  ///
  /// ## Ce que remplace cette méthode
  ///
  /// Android renouvelle périodiquement son adresse MAC : la même personne
  /// apparaissait donc deux fois, puis l'ancienne ligne s'éteignait toute
  /// seule. La correction d'alors — retirer l'entrée perdante et *se souvenir*
  /// de refermer son transport plus tard — a produit la boucle `takeMergedAway`,
  /// dupliquée à deux endroits qui ont divergé.
  ///
  /// Ici, la fusion est **immédiate et complète**, et ce qui reste à refermer
  /// est **rendu à l'appelant** au lieu d'être mis de côté : `merged` est la
  /// session abandonnée, dont seul le réseau peut couper la radio. Rien n'est
  /// différé, donc rien ne peut être oublié.
  ({PeerSession session, PeerSession? merged}) identify(
    PeerSession session,
    PingPeerSnapshot snapshot,
  ) {
    session.snapshot = snapshot;
    for (final other in _sessions.toList()) {
      if (identical(other, session)) continue;
      if (other.userId != snapshot.userId) continue;

      // Celle qui tient le lien vivant gagne — une session chiffrée coûte une
      // poignée de main, une adresse ne coûte rien. À défaut, la plus ancienne,
      // pour que la durée de contact ne reparte pas de zéro à chaque MAC.
      final gagnante = (session.link != null)
          ? session
          : (other.link != null)
          ? other
          : (session.firstHeard.isBefore(other.firstHeard) ? session : other);
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
      // `absorb` a repris le lien de la perdante si la gagnante n'en avait pas.
      // S'il en reste un, c'est un vrai doublon physique : au réseau de le
      // couper, dans le même geste que ce retour.
      return (
        session: gagnante,
        merged: perdante.link != null ? perdante : null,
      );
    }
    return (session: session, merged: null);
  }

  /// Les sessions à oublier : plus rien entendu depuis [PresenceRules.forgetAfter].
  List<PeerSession> expired() {
    final now = _now();
    return _sessions.where((s) => s.isExpired(now)).toList();
  }

  /// Retire une session du registre. **Ne ferme rien** — c'est au réseau de
  /// le faire, dans le même geste.
  void _forget(PeerSession session) {
    _sessions.remove(session);
    _byAddress.removeWhere((_, s) => identical(s, session));
    _byToken.removeWhere((_, s) => identical(s, session));
  }

  void remove(PeerSession session) => _forget(session);

  /// La radio s'est arrêtée : plus rien n'est vrai.
  List<PeerSession> drain() {
    final all = _sessions.toList();
    _sessions.clear();
    _byAddress.clear();
    _byToken.clear();
    return all;
  }
}
