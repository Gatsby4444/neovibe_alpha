import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/config/env.dart';
import '../../core/supabase_providers.dart';

/// **Rejoindre un ami : le trajet à pied le plus court** (Jay, 2026-09-26) —
/// la cuisine. Le service d'itinéraires de Mapbox (« Directions », profil
/// piéton) : gratuit jusqu'à 100 000 demandes par mois, puis payant
/// (vérifié sur mapbox.com/pricing le 2026-09-26).
///
/// ⚠️ **Bloqué au premier lancement public** (décision de Jay) : c'est le
/// SERVEUR qui le dit (`map_rules.walking_route_enabled`, RAPPELS), l'app ne
/// fait que cacher le bouton quand il est éteint.

/// Un trajet : les points à suivre, sa longueur et sa durée à pied.
class WalkingRoute {
  const WalkingRoute({
    required this.points,
    required this.distanceM,
    required this.duration,
  });

  /// (latitude, longitude), dans l'ordre du trajet.
  final List<(double, double)> points;
  final double distanceM;
  final Duration duration;

  /// « 605 m · 7 min », « 2,3 km · 28 min ».
  String get libelle {
    final d = distanceM < 1000
        ? '${distanceM.round()} m'
        : '${(distanceM / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
    final min = (duration.inSeconds / 60).ceil();
    final t = min < 60 ? '$min min' : '${min ~/ 60} h ${min % 60} min';
    return '$d · $t';
  }
}

class WalkingRouteService {
  WalkingRouteService({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;

  /// Le trajet à pied de (lat1, lon1) à (lat2, lon2). Nul si aucun trajet.
  Future<WalkingRoute?> route(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) async {
    final uri = Uri.https(
      'api.mapbox.com',
      '/directions/v5/mapbox/walking/$lon1,$lat1;$lon2,$lat2',
      {
        'geometries': 'geojson',
        'overview': 'full',
        'access_token': Env.mapboxToken,
      },
    );
    final r = await _client.get(uri);
    if (r.statusCode != 200) {
      throw StateError("Itinéraire indisponible (${r.statusCode})");
    }
    return parse(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// La réponse de Mapbox → un trajet (séparé pour être testé sans réseau).
  static WalkingRoute? parse(Map<String, dynamic> json) {
    final routes = json['routes'] as List?;
    if (routes == null || routes.isEmpty) return null;
    final r = routes.first as Map<String, dynamic>;
    final coords =
        (r['geometry'] as Map<String, dynamic>)['coordinates'] as List;
    return WalkingRoute(
      // Mapbox donne (longitude, latitude) ; on garde (latitude, longitude).
      points: [
        for (final c in coords.cast<List>())
          ((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ],
      distanceM: (r['distance'] as num).toDouble(),
      duration: Duration(seconds: (r['duration'] as num).round()),
    );
  }
}

final walkingRouteServiceProvider = Provider<WalkingRouteService>(
  (ref) => WalkingRouteService(),
);

/// « Rejoindre » est-il ouvert ? (Le serveur tranche : `map_rules`.)
final walkingRouteEnabledProvider = FutureProvider<bool>((ref) async {
  final r = await ref
      .watch(supabaseProvider)
      .from('map_rules')
      .select('walking_route_enabled')
      .single();
  return r['walking_route_enabled'] == true;
});
