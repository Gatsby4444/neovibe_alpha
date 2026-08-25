import 'dart:async';

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
/// ## ⚠️ Pourquoi un CARREAU et pas une position
///
/// Le GPS ne sait pas faire les 20 m du produit — 4 à 10 m plein ciel, 10 à
/// 30 m en ville, **20 à 100 m en intérieur**, là où l'on se rencontre. À ce
/// seuil le signal est sous le bruit, dans les deux sens : des gens côte à côte
/// invisibles, des gens d'un autre bâtiment affichés.
///
/// Le GPS ne sert donc qu'à dire **où chercher**, à un kilomètre près. Les 20 m
/// viennent du BLE, qui ne dépend d'aucun satellite. Conséquence heureuse :
/// **cette chaîne est indifférente à la qualité du GPS**, ce qu'aucune variante
/// « GPS précis » ne peut être.
///
/// Corollaire : on demande la précision la **plus basse** qui tienne la
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

/// Ce que l'acquisition constate : une position, réduite d'avance.
///
/// ⚠️ **L'égalité est celle du CARREAU, pas de la position.** C'est ce qui fait
/// qu'un téléphone posé sur une table ne réveille personne : le GPS bouge de
/// quelques mètres en permanence, le carreau ne bouge pas. Sans cette égalité,
/// on republierait une balise toutes les secondes pour rien.
class CoarseFix {
  const CoarseFix({
    required this.cellLat,
    required this.cellLon,
    required this.latitude,
    required this.longitude,
  });

  final int cellLat;
  final int cellLon;

  /// La position brute. ⚠️ **Ne jamais la stocker ni l'envoyer telle quelle** —
  /// elle n'est là que parce que le serveur veut arrondir lui-même, pour ne pas
  /// dépendre de ce que le client veut bien arrondir.
  final double latitude;
  final double longitude;

  static CoarseFix of(Position p) => CoarseFix(
    cellLat: (p.latitude / kCellSizeDegrees).floor(),
    cellLon: (p.longitude / kCellSizeDegrees).floor(),
    latitude: p.latitude,
    longitude: p.longitude,
  );

  @override
  bool operator ==(Object other) =>
      other is CoarseFix &&
      other.cellLat == cellLat &&
      other.cellLon == cellLon;

  @override
  int get hashCode => Object.hash(cellLat, cellLon);

  @override
  String toString() => 'carreau($cellLat, $cellLon)';
}

/// Pourquoi la position n'est pas disponible. **Chaque cas nomme une action.**
///
/// ⚠️ Même règle que `RadioStatus` : aucune valeur ne signifie « peut-être ».
/// Un état qu'on ne sait pas nommer est un état qu'on ne saura pas corriger.
enum LocationBlocker {
  /// Le service de localisation de l'appareil est éteint.
  serviceOff,

  /// L'utilisateur a refusé, mais on peut redemander.
  denied,

  /// Refusé définitivement : seuls les réglages système peuvent le rouvrir.
  deniedForever,

  /// Accordée, mais **approximative** — et ça ne suffit pas.
  ///
  /// ⚠️ Depuis Android 12, l'utilisateur peut n'accorder que la position
  /// approximative : Android répond alors à ~3 km près. Notre carreau fait
  /// 1 km et le voisinage interrogé 3 km — une erreur de 3 km peut donc placer
  /// deux personnes côte à côte dans des blocs entièrement différents.
  ///
  /// **Ce cas doit se DIRE.** Sans lui, le ping rendrait simplement une liste
  /// vide, indiscernable de « personne autour » — le défaut silencieux que ce
  /// projet passe son temps à traquer.
  approximate,
}

/// Au-delà de cette erreur annoncée, la position ne situe plus dans le bon
/// carreau. **Mesurée, pas devinée** : Android publie son incertitude dans
/// `Position.accuracy` (rayon de confiance à 68 %).
const double kMaxAccuracyMeters = 500;

/// L'acquisition. **Publie ce qu'elle constate, ne décide de rien.**
class CoarseLocation {
  const CoarseLocation();

  /// Ce qui empêche de lire une position, ou `null` si rien.
  ///
  /// ⚠️ **Ne demande PAS la permission** : constater et demander sont deux
  /// gestes différents, et c'est la vue qui décide du moment où l'on dérange
  /// l'utilisateur.
  Future<LocationBlocker?> blocker() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceOff;
    }
    final permission = await Geolocator.checkPermission();
    return switch (permission) {
      LocationPermission.denied => LocationBlocker.denied,
      LocationPermission.deniedForever => LocationBlocker.deniedForever,
      // ⚠️ Android 12+ : accordée, mais approximative. Voir
      // [LocationBlocker.approximate].
      LocationPermission.whileInUse ||
      LocationPermission.always => await _accuracyBlocker(),
      _ => null,
    };
  }

  /// La précision réellement accordée suffit-elle ?
  Future<LocationBlocker?> _accuracyBlocker() async {
    final last = await Geolocator.getLastKnownPosition();
    if (last == null) return null; // rien à dire encore
    return last.accuracy > kMaxAccuracyMeters
        ? LocationBlocker.approximate
        : null;
  }

  /// Demande la permission. Rend ce qui bloque encore, ou `null`.
  Future<LocationBlocker?> request() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceOff;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.denied => LocationBlocker.denied,
      LocationPermission.deniedForever => LocationBlocker.deniedForever,
      _ => null,
    };
  }

  /// Le flux des carreaux traversés.
  ///
  /// ⚠️ **`distanceFilter` à 200 m et précision `low`, délibérément.** On
  /// cherche un carreau d'un kilomètre : demander mieux, ou plus souvent, ne
  /// changerait pas une seule liste et viderait la batterie. C'est la règle
  /// « la couche d'acquisition publie fidèlement » appliquée au coût : on
  /// n'acquiert pas plus fin que ce dont le produit a besoin.
  Stream<CoarseFix> watch() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.low,
      distanceFilter: 200,
    ),
  ).map(CoarseFix.of);

  /// Une position tout de suite, pour ne pas attendre le premier mouvement.
  Future<CoarseFix?> current() async {
    if (await blocker() != null) return null;
    final last = await Geolocator.getLastKnownPosition();
    if (last != null && last.accuracy <= kMaxAccuracyMeters) {
      return CoarseFix.of(last);
    }
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 20),
        ),
      );
      // ⚠️ **On lit l'incertitude ANNONCÉE, on ne suppose pas la précision.**
      // Une position à 3 km d'incertitude est une position approximative, quel
      // que soit ce que l'utilisateur croit avoir accordé.
      if (p.accuracy > kMaxAccuracyMeters) return null;
      return CoarseFix.of(p);
    } on TimeoutException {
      return null;
    }
  }
}

final coarseLocationProvider = Provider((ref) => const CoarseLocation());
