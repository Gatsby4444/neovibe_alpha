import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/proximity/geo/live_position.dart';

/// **L'ancre d'un contenu** : où il a été pris — **gommée**, jamais exacte.
///
/// Jay, 2026-09-20 : localiser une publication est un consentement à part de
/// « Public », non par défaut, parce que *« c'est parfois chez quelqu'un »*.
/// Et même quand l'auteur dit oui, on ne retient que **la case de 100 m** où
/// le point tombe : l'app gomme avant d'envoyer, le serveur gomme avant
/// d'écrire (`private.gomme_ancre`), avec la même règle. Le point exact
/// n'existe nulle part.
class ContentAnchor {
  const ContentAnchor({required this.lat, required this.lng});

  factory ContentAnchor.fromJson(Map<String, dynamic> j) => ContentAnchor(
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
  );

  final double lat;
  final double lng;

  /// La taille de la case, en mètres — la même que `feed_rules.anchor_cell_m`.
  static const cellM = 100;

  /// Un mètre de latitude, en degrés.
  static const _metersPerDegree = 111320.0;

  /// Gomme un point sur la grille de [cellM] : on ne garde que sa case.
  /// Miroir exact de `private.gomme_ancre`.
  static ContentAnchor gomme(double lat, double lng, {int cellM = cellM}) {
    final stepLat = cellM / _metersPerDegree;
    final gLat = (lat / stepLat).round() * stepLat;
    final stepLng = stepLat / math.max(math.cos(gLat * math.pi / 180), 0.01);
    final gLng = (lng / stepLng).round() * stepLng;
    return ContentAnchor(lat: gLat, lng: gLng);
  }

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  @override
  bool operator ==(Object other) =>
      other is ContentAnchor && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);
}

/// D'où vient une ancre : la position de l'appareil, si l'utilisateur l'a
/// accordée (« pendant l'utilisation », la même que le ping), déjà gommée.
/// Rend `null` sans rien demander : demander est le geste d'un écran.
class AnchorSource {
  const AnchorSource(this._ref);
  final Ref _ref;

  Future<ContentAnchor?> current() async {
    final fix = await _ref.read(livePositionProvider.notifier).current();
    if (fix == null) return null;
    return ContentAnchor.gomme(fix.latitude, fix.longitude);
  }
}

final anchorSourceProvider = Provider((ref) => AnchorSource(ref));
