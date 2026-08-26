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

/// Ce que l'acquisition constate : une position, et ce qu'elle vaut.
class CoarseFix {
  const CoarseFix({
    required this.cellLat,
    required this.cellLon,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
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

  static CoarseFix of(Position p) => CoarseFix(
    cellLat: (p.latitude / kCellSizeDegrees).floor(),
    cellLon: (p.longitude / kCellSizeDegrees).floor(),
    latitude: p.latitude,
    longitude: p.longitude,
    accuracy: p.accuracy,
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
      other.accuracy == accuracy;

  @override
  int get hashCode =>
      Object.hash(cellLat, cellLon, latitude, longitude, accuracy);

  /// ⚠️ Lu tel quel dans le rapport de diagnostic : l'incertitude en fait
  /// partie, sans quoi un carreau juste et un carreau deviné se ressemblent.
  @override
  String toString() => 'carreau($cellLat, $cellLon) ± ${accuracy.round()} m';
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

  /// Une position tout de suite, pour ne pas attendre le premier mouvement.
  ///
  /// ⚠️ **On ne renonce plus sur la précision.** Cette méthode refusait tout
  /// point au-delà de 500 m d'incertitude — et comme elle interrogeait le cache
  /// en premier, un vieux point réseau imprécis suffisait à ce qu'**aucune
  /// lecture GPS ne soit jamais tentée**. La balise ne partait pas, et l'écran
  /// d'en face affichait « personne aux alentours » (panne du 2026-08-26).
  ///
  /// Une position imprécise n'est pas une position fausse : c'est un carreau
  /// peut-être voisin du bon. Au pire on ne trouve personne — exactement ce que
  /// produisait le refus, mais sans le dire. La dégradation, elle, se dit :
  /// [precision].
  Future<CoarseFix?> current() async {
    if (await blocker() != null) return null;
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return CoarseFix.of(p);
    } on TimeoutException {
      // Le cache n'est qu'un **repli**, jamais la source première : c'est
      // l'ordre inverse qui figeait la chaîne sur un vieux point.
      //
      // ⚠️ Le coût est assumé : une lecture par minute (`refreshEvery`), en
      // précision `low`, c'est-à-dire réseau plutôt que satellites. Une balise
      // dit « où je suis MAINTENANT » — un point vieux de plusieurs heures y
      // serait faux, pas économe.
      final last = await Geolocator.getLastKnownPosition();
      return last == null ? null : CoarseFix.of(last);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      return last == null ? null : CoarseFix.of(last);
    }
  }
}

final coarseLocationProvider = Provider((ref) => const CoarseLocation());
