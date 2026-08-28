import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// **L'ACQUISITION de la position, et rien d'autre.**
///
/// ## Ce que ce module sait, et ce qu'il ignore
///
/// Il sait lire une position et la réduire à un **carreau**. Il ne sait pas ce
/// qu'est un ping, ni un ami, ni un profil. Il publie ce qu'il constate ; qui le
/// lit en fait ce qu'il veut. Règle de Jay du 2026-08-25 : *on ne mélange plus
/// cuisine, serveurs et clients.*
///
/// ## ⚠️ La position ORIENTE, elle ne prouve jamais
///
/// Le GPS ne sait pas faire les 20 m du produit — 4 à 10 m plein ciel, 10 à
/// 30 m en ville, **20 à 100 m en intérieur**, là où l'on se rencontre. À ce
/// seuil le signal est sous le bruit, dans les deux sens : des gens côte à côte
/// invisibles, des gens d'un autre bâtiment affichés.
///
/// Elle sert donc à dire **où chercher**. Les 20 m viennent du BLE, qui ne
/// dépend d'aucun satellite. Conséquence heureuse : **cette chaîne est
/// indifférente à la qualité du GPS**, ce qu'aucune variante « GPS précis » ne
/// peut être.
///
/// ⚠️ **Depuis le 2026-08-26, la position exacte est transmise et conservée**
/// (décision de Jay). Ce module publiait auparavant un carreau et jetait le
/// reste. Ce que ça débloque est côté serveur : un filtre par distance réelle,
/// une barrière contre l'attaque par relais, et le clustering à venir. Ce que ça
/// ne change pas : la ligne ci-dessus. La position n'a pas gagné en autorité en
/// gagnant en finesse.
///
/// Corollaire inchangé : on demande la précision la **plus basse** qui tienne la
/// promesse. Demander mieux coûterait de la batterie pour rien.
///
/// ## ⚠️ Premier plan uniquement
///
/// Aucune position n'est lue quand l'app est fermée. C'est ce qui permet de
/// n'exiger que la permission « **pendant l'utilisation** » — jamais
/// « Autoriser tout le temps », l'invite la plus dissuasive d'Android, sur une
/// app dont la thèse est la confiance.
///
/// Le croisement d'amis, lui, n'utilise **pas** ce module : il vit en BLE, il
/// fonctionne app fermée, et il ne demande aucune permission de localisation
/// sur Android 12+.

/// Le côté d'un carreau, en degrés.
///
/// 0,01° ≈ 1,11 km en latitude et ≈ 0,79 km en longitude à 45°.
///
/// ⚠️ **Doit rester égal à `private.ping_cell_size()` côté serveur.** Deux
/// valeurs qui divergent ne lèveraient aucune erreur : les listes seraient
/// simplement fausses, et personne ne le verrait.
const double kCellSizeDegrees = 0.01;

/// **Quel palier d'Android a répondu.**
///
/// ## ⚠️ Pourquoi c'est un fait publié, et pas une note interne
///
/// Le 2026-08-28, deux appareils côte à côte se sont crus à 1,5 km l'un de
/// l'autre et le serveur a refusé de les apparier. Le rapport disait
/// « ± 400 m » — et ce nombre seul ne permet PAS de trancher entre *« on a
/// demandé le meilleur et le ciel n'a pas répondu »* et *« on n'a jamais
/// demandé le meilleur »*. C'était le second cas, et il a fallu lire le code du
/// paquet `geolocator` pour le savoir.
///
/// ⚠️ **Ce nom dit ce qu'on a DEMANDÉ, jamais ce qui a contribué.** Android ne
/// dit pas si les satellites ont servi : [best] peut très bien être une réponse
/// Wi-Fi, à l'intérieur. Le prétendre serait inventer une mesure.
enum FixSource {
  /// `PRIORITY_HIGH_ACCURACY` : GPS + Wi-Fi + antennes + capteurs.
  best,

  /// `PRIORITY_BALANCED_POWER_ACCURACY` : Wi-Fi + antennes, sans satellites.
  ///
  /// ⚠️ **Le seul palier qui marche à l'intérieur sans satellites** — et le
  /// seul qui NE marche PAS dehors sans réseau. Les deux sont complémentaires,
  /// c'est pourquoi il y a un repli et pas un choix.
  network,

  /// Le dernier point connu, retenu **uniquement** s'il est encore frais.
  lastKnown,
}

/// Ce que l'acquisition constate : une position, et ce qu'elle vaut.
class CoarseFix {
  const CoarseFix({
    required this.cellLat,
    required this.cellLon,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.source,
  });

  final int cellLat;
  final int cellLon;

  /// La position, telle que l'appareil l'a mesurée.
  ///
  /// ⚠️ **Elle est CONSERVÉE côté serveur depuis le 2026-08-26** (décision de
  /// Jay). Elle sert à filtrer par distance réelle plutôt que par grille, et à
  /// refuser une attaque par relais. Le carreau, lui, continue d'être calculé
  /// par le serveur — non pour empêcher un client de mentir (il peut de toute
  /// façon inventer sa position) mais pour qu'il n'existe **qu'une seule**
  /// définition de la taille de la grille.
  final double latitude;
  final double longitude;

  /// L'incertitude **annoncée** par l'appareil, en mètres — le rayon de
  /// confiance à 68 % que publie Android dans `Position.accuracy`.
  ///
  /// ⚠️ **C'est elle qui rend le filtre par distance honnête.** Un rayon fixe
  /// ferait disparaître de la liste des gens réellement à portée dès que la
  /// position est mauvaise — et rien ne le dirait. Ici, quand on sait mal où
  /// l'on est, on cherche plus large : `private.ping_reach` côté serveur.
  final double accuracy;

  /// Le palier qui a répondu. Voir [FixSource].
  final FixSource source;

  static CoarseFix of(Position p, FixSource source) => CoarseFix(
    cellLat: (p.latitude / kCellSizeDegrees).floor(),
    cellLon: (p.longitude / kCellSizeDegrees).floor(),
    latitude: p.latitude,
    longitude: p.longitude,
    accuracy: p.accuracy,
    source: source,
  );

  /// ⚠️ **L'égalité porte sur toute la mesure, plus seulement sur le carreau.**
  ///
  /// Elle valait « même carreau = même chose », ce qui était vrai tant que le
  /// carreau était la seule chose transmise. Depuis que la position exacte part
  /// au serveur, cette égalité mentirait : deux points distants de 900 m dans
  /// le même carreau se seraient dits identiques, et tout code qui s'en servirait
  /// pour décider s'il faut republier **figerait la position** — le point H, en
  /// géographie.
  @override
  bool operator ==(Object other) =>
      other is CoarseFix &&
      other.cellLat == cellLat &&
      other.cellLon == cellLon &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.accuracy == accuracy &&
      other.source == source;

  @override
  int get hashCode =>
      Object.hash(cellLat, cellLon, latitude, longitude, accuracy, source);

  /// ⚠️ Lu tel quel dans le rapport de diagnostic : l'incertitude en fait
  /// partie, sans quoi un carreau juste et un carreau deviné se ressemblent.
  @override
  String toString() =>
      'carreau($cellLat, $cellLon) ± ${accuracy.round()} m · ${source.name}';
}

/// Pourquoi la position n'est pas disponible **du tout**. Chaque cas nomme une
/// action.
///
/// ⚠️ Même règle que `RadioStatus` : aucune valeur ne signifie « peut-être ».
/// Un état qu'on ne sait pas nommer est un état qu'on ne saura pas corriger.
///
/// ⚠️ **« Approximative » n'est PAS ici, et c'est la correction du
/// 2026-08-26.** Voir [LocationPrecision] : une position imprécise reste une
/// position, donc un fait publiable. En faire un blocage garantissait l'échec
/// là où publier quand même ne donnait, au pire, que le même échec.
enum LocationBlocker {
  /// Le service de localisation de l'appareil est éteint.
  serviceOff,

  /// L'utilisateur a refusé, mais on peut redemander.
  denied,

  /// Refusé définitivement : seuls les réglages système peuvent le rouvrir.
  deniedForever,

  /// **Tout est autorisé, et aucun palier n'a su répondre.**
  ///
  /// ⚠️ **Ajouté le 2026-08-28, et c'est une valeur qui manquait.** Le repli
  /// sur le dernier point connu est désormais borné dans le temps
  /// ([CoarseLocation.maxLastKnownAge]) : il existe donc un cas — dedans, sans
  /// Wi-Fi, sans réseau, sans point récent — où l'on n'a **rien** à publier.
  ///
  /// Sans ce cas nommé, l'écran affichait « personne d'autre n'a le ping activé
  /// dans ton quartier » : un mensonge, puisqu'on ne s'était pas annoncé
  /// soi-même. Exactement le défaut silencieux que ce projet traque partout.
  noFix,
}

/// La finesse **réellement accordée** par Android.
///
/// ## ⚠️ Pourquoi c'est un état à part, et pas un blocage
///
/// Depuis Android 12, l'utilisateur peut n'accorder que la position
/// approximative : Android répond alors à ~3 km près.
///
/// ⚠️ **Mesuré le 2026-08-26, contre ce que ce commentaire affirmait avant** :
/// le voisinage de 3×3 carreaux fait 3 km de LARGE, mais la portée **garantie**
/// autour de soi n'est que d'un carreau — de 0,79 à 1,11 km selon l'axe. Deux
/// personnes distantes de 1,5 km tombent déjà à deux carreaux d'écart, donc hors
/// liste. Une erreur de 3 km ne dégrade donc pas la découverte : **elle
/// l'empêche.** D'où l'avertissement, qui n'est pas une précaution de style.
///
/// C'est une **dégradation**, pas une impossibilité : au pire on ne trouve
/// personne, ce qui est exactement ce que produisait le blocage. On publie
/// donc, et on le **dit** — sans quoi une liste vide serait indiscernable de
/// « personne autour », le défaut silencieux que ce projet traque partout.
///
/// ## ⚠️ Ce fait se relève, il ne se devine pas
///
/// Il valait `getLastKnownPosition().accuracy > 500 m` — un raisonnement sur un
/// **cache**, pas sur une permission. Un dernier point issu du réseau dépasse
/// couramment 500 m alors même que la position précise est accordée : l'app
/// réclamait alors un réglage déjà fait, et le message était sans issue (panne
/// du 2026-08-26). La réponse vient maintenant du natif, qui lit la permission
/// (`LocationGrant`, canal `neovibe/location`).
enum LocationPrecision {
  /// `ACCESS_FINE_LOCATION` accordée : quelques mètres à quelques dizaines.
  precise,

  /// Seule `ACCESS_COARSE_LOCATION` l'est : Android répond à ~3 km près.
  approximate,
}

/// L'acquisition. **Publie ce qu'elle constate, ne décide de rien.**
class CoarseLocation {
  const CoarseLocation();

  /// Le canal qui dit ce qu'Android a **réellement accordé**. Voir
  /// [LocationPrecision] et `android/.../LocationGrant.kt`.
  static const _grant = MethodChannel('neovibe/location');

  /// Ce qui empêche de lire une position, ou `null` si rien.
  ///
  /// ⚠️ **Ne demande PAS la permission** : constater et demander sont deux
  /// gestes différents, et c'est la vue qui décide du moment où l'on dérange
  /// l'utilisateur.
  Future<LocationBlocker?> blocker() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceOff;
    }
    return switch (await Geolocator.checkPermission()) {
      LocationPermission.denied => LocationBlocker.denied,
      LocationPermission.deniedForever => LocationBlocker.deniedForever,
      _ => null,
    };
  }

  /// La finesse réellement accordée. **Relevée auprès d'Android**, jamais
  /// déduite de la précision d'un point en cache (panne du 2026-08-26).
  ///
  /// ⚠️ En cas d'échec du canal, on répond [LocationPrecision.precise] : sur
  /// une plateforme sans ce pont, l'ancien comportement — publier — vaut mieux
  /// qu'un avertissement permanent que personne ne peut lever. Un doute ne doit
  /// pas se transformer en reproche à l'utilisateur.
  Future<LocationPrecision> precision() async {
    try {
      final grant = await _grant.invokeMapMethod<String, dynamic>('grant');
      return (grant?['fine'] as bool? ?? true)
          ? LocationPrecision.precise
          : LocationPrecision.approximate;
    } catch (_) {
      return LocationPrecision.precise;
    }
  }

  /// Demande la permission. Rend ce qui bloque encore, ou `null`.
  ///
  /// ⚠️ **On redemande même quand la permission est déjà « accordée ».** C'est
  /// ce qui permet de récupérer la position précise après un premier
  /// « Approximative » : Android affiche alors sa boîte de mise à niveau, la
  /// seule façon de la rouvrir sans passer par les réglages système. Sans ce
  /// second appel, le bandeau ne proposait qu'« Ouvrir les réglages » — et Jay
  /// y a cherché en vain une autorisation qui ne s'y trouvait pas.
  Future<LocationBlocker?> request() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceOff;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        await precision() == LocationPrecision.approximate) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.denied => LocationBlocker.denied,
      LocationPermission.deniedForever => LocationBlocker.deniedForever,
      _ => null,
    };
  }

  /// **Une position, au meilleur palier qu'Android accepte de donner.**
  ///
  /// ## ⚠️ Ce qui a changé le 2026-08-28, et pourquoi (décision de Jay)
  ///
  /// Cette méthode demandait [LocationAccuracy.low]. Vérifié dans le paquet —
  /// `geolocator_android-4.6.2/.../FusedLocationClient.java:136` :
  ///
  /// | `LocationAccuracy` | Priorité Android | Ce qu'Android utilise |
  /// |---|---|---|
  /// | `lowest` | `PRIORITY_PASSIVE` | rien : on récupère ce que d'autres apps demandent |
  /// | `low` ← **l'ancien** | `PRIORITY_LOW_POWER` | **antennes réseau seules**, classe 10 km |
  /// | `medium` | `PRIORITY_BALANCED_POWER_ACCURACY` | Wi-Fi + antennes, classe 100 m |
  /// | `high` | `PRIORITY_HIGH_ACCURACY` | GPS + Wi-Fi + antennes + capteurs |
  ///
  /// ⚠️ **Le service fusionné d'Android croise bien plusieurs sources — mais
  /// seulement à partir de `medium`.** `low` est précisément le palier qui
  /// n'utilise **ni** le GPS **ni** le Wi-Fi. On demandait donc la position la
  /// moins bonne qu'Android sache produire.
  ///
  /// ⚠️ **La décision d'origine n'était pas fausse, elle s'est périmée.** Tant
  /// que la position ne servait qu'à choisir un carreau d'un kilomètre, le
  /// palier réseau suffisait et coûtait moins de batterie. Le 2026-08-26, un
  /// **filtre en mètres** est apparu côté serveur — et personne n'est revenu
  /// rejouer le choix d'économie qui le précédait. Règle de `CLAUDE.md` : une
  /// décision se périme quand sa prémisse bouge.
  ///
  /// ## L'ordre, et pourquoi ce n'est pas « le meilleur puis un lot de
  /// consolation »
  ///
  /// [FixSource.best] sait tout ce que [FixSource.network] sait, **plus** les
  /// satellites. Le repli n'existe donc pas pour couvrir un manque de
  /// connaissance, mais un manque de **temps** : un GPS froid peut chercher
  /// longtemps, quand le réseau répond de mémoire. D'où deux bornes de temps.
  ///
  /// Et les deux paliers sont complémentaires aux extrêmes :
  ///
  /// | Situation | `best` | `network` |
  /// |---|---|---|
  /// | dehors, sans réseau ni Wi-Fi | ✅ satellites | ❌ rien à interroger |
  /// | dedans, sans satellites | ✅ retombe sur le Wi-Fi | ✅ |
  /// | dedans, sans réseau **ni** Wi-Fi | ❌ | ❌ → [FixSource.lastKnown] |
  Future<CoarseFix?> current() async {
    if (await blocker() != null) return null;

    final best = await _read(
      LocationAccuracy.high,
      _bestTimeLimit,
      FixSource.best,
    );
    if (best != null) return best;

    final network = await _read(
      LocationAccuracy.medium,
      _networkTimeLimit,
      FixSource.network,
    );
    if (network != null) return network;

    return _lastKnownIfFresh();
  }

  /// Combien de temps on laisse au meilleur palier avant de se replier.
  ///
  /// Somme des deux bornes : 17 s, sous la cadence d'un tour de balise
  /// (`PingBeaconService.refreshEvery`, 60 s). Un tour ne peut donc jamais
  /// mordre sur le suivant.
  static const _bestTimeLimit = Duration(seconds: 12);

  /// Le repli n'attend rien : ce qu'il rend est déjà calculé quelque part.
  static const _networkTimeLimit = Duration(seconds: 5);

  /// Au-delà, un dernier point connu n'est plus « où je suis ».
  ///
  /// ## ⚠️ Cette borne n'existait pas, et c'était une panne en attente
  ///
  /// Le repli prenait `getLastKnownPosition()` **sans regarder sa date**. Un
  /// point vieux de plusieurs heures partait donc comme balise courante : on
  /// s'annonçait là où l'on n'était plus, et le serveur appariait des gens qui
  /// ne se sont jamais vus — ou refusait ceux qui étaient côte à côte. Rien ne
  /// l'aurait signalé : une position périmée a exactement la forme d'une
  /// position juste.
  ///
  /// **Cinq minutes**, pour une raison qui se vérifie et non par goût :
  /// c'est `private.ping_beacon_ttl()`. Publier comme position courante un
  /// point plus vieux que la durée de vie de la balise qu'on écrit serait
  /// incohérent par construction. À pied (~5 km/h), cinq minutes font ~400 m —
  /// moins d'un carreau.
  static const maxLastKnownAge = Duration(minutes: 5);

  /// **La règle de fraîcheur, isolée pour être éprouvable.**
  ///
  /// ⚠️ Séparée parce que se tromper ici ne lève rien : une borne trop large
  /// publie une position fausse, une borne trop courte rend muet — et les deux
  /// s'affichent comme « personne autour ».
  /// ⚠️ Un point daté dans le FUTUR (horloge décalée) est accepté : il n'est
  /// pas périmé, et une soustraction négative est déjà `<= maxLastKnownAge`.
  /// Le dire ici évite qu'on « corrige » un jour ce qui n'est pas un oubli.
  static bool isFreshEnough(DateTime fixedAt, DateTime now) =>
      now.difference(fixedAt) <= maxLastKnownAge;

  Future<CoarseFix?> _read(
    LocationAccuracy accuracy,
    Duration limit,
    FixSource source,
  ) async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: limit,
        ),
      );
      return CoarseFix.of(p, source);
    } catch (_) {
      // Délai dépassé, palier indisponible, service coupé entre-temps : dans
      // tous les cas il n'y a rien à publier **par ce palier**. C'est
      // [current] qui décide de la suite — pas nous.
      return null;
    }
  }

  Future<CoarseFix?> _lastKnownIfFresh() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return null;
      if (!isFreshEnough(last.timestamp, DateTime.now())) return null;
      return CoarseFix.of(last, FixSource.lastKnown);
    } catch (_) {
      return null;
    }
  }
}

final coarseLocationProvider = Provider((ref) => const CoarseLocation());
