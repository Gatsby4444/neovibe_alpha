import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/app_log.dart';
import '../supabase_providers.dart';
import 'anchor.dart';

/// **Quand et où une Vibe a été prise** (Jay, 2026-09-25 : *« on enregistre
/// toujours le lieu de prise ; s'il ne désire pas explicitement le partager,
/// la position n'est pas partagée »*).
class CaptureStamp {
  const CaptureStamp({required this.takenAt, this.anchor});

  final DateTime takenAt;

  /// La case de 100 m ([ContentAnchor.gomme]) — nulle si la position
  /// n'était pas disponible à la prise.
  final ContentAnchor? anchor;

  @override
  bool operator ==(Object other) =>
      other is CaptureStamp &&
      other.takenAt == takenAt &&
      other.anchor?.lat == anchor?.lat &&
      other.anchor?.lng == anchor?.lng;

  @override
  int get hashCode => Object.hash(takenAt, anchor?.lat, anchor?.lng);
}

/// Le journal **privé** des lieux de prise : `capture_places`, une ligne par
/// objet serveur né d'une prise (Card, Vibe de Drop, story, publication),
/// lisible par son seul auteur (politique RLS). Le PARTAGE d'une position
/// est un autre objet (`contents.anchor_*`, « Localiser ») : ce journal n'y
/// mène jamais.
class CapturePlaces {
  CapturePlaces(this.ref);
  final Ref ref;

  /// Note le lieu de prise de [objectId]. Ne lève jamais : un lieu manquant
  /// n'empêche pas un envoi — il est journalisé.
  Future<void> record(String objectId, CaptureStamp stamp) async {
    try {
      await ref.read(supabaseProvider).from('capture_places').upsert({
        'object_id': objectId,
        'owner_id': ref.read(currentUserIdProvider),
        'taken_at': stamp.takenAt.toUtc().toIso8601String(),
        'lat': stamp.anchor?.lat,
        'lon': stamp.anchor?.lng,
      });
    } catch (e) {
      AppLog.instance.error('Lieu de prise non noté', 'objet=$objectId · $e');
    }
  }

  /// Le lieu de prise de MON objet, ou nul (pas le mien, ou pas noté).
  Future<CaptureStamp?> of(String objectId) async {
    try {
      final row = await ref
          .read(supabaseProvider)
          .from('capture_places')
          .select()
          .eq('object_id', objectId)
          .maybeSingle();
      if (row == null) return null;
      final lat = (row['lat'] as num?)?.toDouble();
      final lon = (row['lon'] as num?)?.toDouble();
      return CaptureStamp(
        takenAt: DateTime.parse(row['taken_at'] as String).toLocal(),
        anchor: lat == null || lon == null
            ? null
            : ContentAnchor(lat: lat, lng: lon),
      );
    } catch (_) {
      return null;
    }
  }
}

final capturePlacesProvider = Provider(CapturePlaces.new);
