import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/library_item.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../proximity/geo/live_position.dart';

/// **Les Vibes publiques autour de moi, sur la carte** (Jay, 2026-09-26) —
/// la cuisine. La règle vit au serveur (`private.vibes_autour`, partagée avec
/// Pulse) : publiques, SITUÉES par leur auteur, récentes, non retirées ; les
/// plus aimées et les plus récentes dans 3 km (`map_rules`).

/// Une Vibe sur la carte : où, combien de « j'aime », populaire ou non.
class MapVibe {
  const MapVibe({
    required this.id,
    required this.lat,
    required this.lng,
    required this.likes,
    required this.populaire,
  });

  factory MapVibe.fromJson(Map<String, dynamic> j) => MapVibe(
    id: j['id'] as String,
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    likes: (j['likes'] as num?)?.toInt() ?? 0,
    populaire: j['populaire'] == true,
  );

  final String id;
  final double lat;
  final double lng;
  final int likes;

  /// Parmi les plus aimées du coin (sinon : parmi les plus récentes).
  final bool populaire;

  @override
  bool operator ==(Object other) =>
      other is MapVibe &&
      other.id == id &&
      other.lat == lat &&
      other.lng == lng &&
      other.likes == likes &&
      other.populaire == populaire;

  @override
  int get hashCode => Object.hash(id, lat, lng, likes, populaire);
}

class VibesMapRepository {
  VibesMapRepository(this._client);
  final SupabaseClient _client;

  Future<List<MapVibe>> around(double lat, double lng) async {
    final rows =
        await _client.rpc(
              'map_vibes_around',
              params: {'p_lat': lat, 'p_lng': lng},
            )
            as List;
    return [
      for (final r in rows)
        MapVibe.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  /// Les Vibes elles-mêmes, pour le lecteur — le serveur ne rend que celles
  /// que la règle laisse voir, quels que soient les identifiants demandés.
  Future<List<LibraryItem>> items(
    List<String> ids,
    double lat,
    double lng,
  ) async {
    if (ids.isEmpty) return const [];
    final rows = await _client
        .rpc(
          'map_vibe_items',
          params: {'p_ids': ids, 'p_lat': lat, 'p_lng': lng},
        )
        .select(LibraryItem.select);
    return [
      for (final r in rows as List)
        LibraryItem.fromJson(r as Map<String, dynamic>),
    ];
  }
}

final vibesMapRepositoryProvider = Provider<VibesMapRepository>(
  (ref) => VibesMapRepository(ref.watch(supabaseProvider)),
);

/// **Les Vibes autour de moi, pour la carte** — rien si l'utilisateur les a
/// masquées (roue de la carte). Relu à l'ouverture de la carte et quand le
/// réglage change ; `autoDispose` : carte fermée, plus rien.
final mapVibesProvider = FutureProvider.autoDispose<List<MapVibe>>((ref) async {
  if (!ref.watch(mapShowVibesProvider)) return const [];
  if (ref.watch(currentUserIdProvider) == null) return const [];
  final fix = await ref.read(livePositionProvider.notifier).current();
  if (fix == null) return const [];
  return ref
      .watch(vibesMapRepositoryProvider)
      .around(fix.latitude, fix.longitude);
});
