import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/models/event.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../proximity/geo/coarse_location.dart';
import 'event_screen.dart';
import 'events_providers.dart';

/// **La carte** (étape 5 du programme du 2026-09-21) : les soirées à portée
/// autour de moi, et — dans l'événement où je suis — ses points chauds.
///
/// Le fond de carte est OpenStreetMap, avec le nom du paquet en
/// `User-Agent` comme sa politique l'exige. ⚠️ C'est un fond **gratuit et
/// limité** : bon pour tester, pas pour la production (RAPPELS). Rien
/// n'est envoyé au serveur depuis cet écran ; il lit les mêmes vues que la
/// liste.
class EventsMapScreen extends ConsumerStatefulWidget {
  const EventsMapScreen({super.key, this.eventId});

  /// Un événement à centrer (ses points chauds) ; nul = autour de moi.
  final String? eventId;

  @override
  ConsumerState<EventsMapScreen> createState() => _EventsMapScreenState();
}

class _EventsMapScreenState extends ConsumerState<EventsMapScreen> {
  CoarseFix? _me;

  @override
  void initState() {
    super.initState();
    ref.read(coarseLocationProvider).current().then((fix) {
      if (mounted) setState(() => _me = fix);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final eventId = widget.eventId;
    final event = eventId == null
        ? null
        : ref.watch(eventByIdProvider(eventId));
    final nearby = eventId == null
        ? ref.watch(nearbyEventsProvider)
        : const AsyncValue<List<NearbyEvent>>.data([]);
    final spots = eventId == null
        ? const <HotSpot>[]
        : ref.watch(eventHotSpotsProvider(eventId)).value ?? const [];

    final me = _me;
    final center = event?.lat != null
        ? LatLng(event!.lat!, event.lon!)
        : spots.isNotEmpty
        ? LatLng(spots.first.lat, spots.first.lon)
        : me != null
        ? LatLng(me.latitude, me.longitude)
        : const LatLng(50.63, 3.06);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(event?.title ?? 'Autour de moi'),
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 15),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.neovibe.neovibe',
              ),
              // Les points chauds d'un événement : un cercle par cellule de
              // 50 m, proportionnel au monde qu'il y a.
              CircleLayer(
                circles: [
                  for (final s in spots)
                    CircleMarker(
                      point: LatLng(s.lat, s.lon),
                      radius: 12.0 + 4 * s.headcount.clamp(0, 10),
                      color: p.action.withValues(alpha: 0.25),
                      borderColor: p.action,
                      borderStrokeWidth: 1.5,
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (me != null)
                    Marker(
                      point: LatLng(me.latitude, me.longitude),
                      width: 24,
                      height: 24,
                      child: Icon(Icons.my_location, color: p.ink, size: 22),
                    ),
                  for (final e in nearby.value ?? const <NearbyEvent>[])
                    Marker(
                      point: LatLng(e.lat, e.lon),
                      width: 120,
                      height: 60,
                      child: _Epingle(event: e),
                    ),
                ],
              ),
            ],
          ),
          if (nearby.hasError)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Material(
                color: p.surface,
                borderRadius: BorderRadius.circular(NeoRadius.md),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    nearby.error is StateError
                        ? 'Active la localisation pour voir les soirées.'
                        : messageServeur(nearby.error!),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 8,
            bottom: 4,
            child: Text(
              '© OpenStreetMap',
              style: TextStyle(
                fontSize: 10,
                color: p.ink.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Une soirée sur la carte : son nom et « N ici ». Un tap ouvre son écran.
class _Epingle extends StatelessWidget {
  const _Epingle({required this.event});
  final NearbyEvent event;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EventScreen(eventId: event.id, preview: event),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.action, width: 1.5),
            ),
            child: Text(
              '${event.title} · ${event.presentCount}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          Icon(
            event.kind == EventKind.open ? Icons.celebration : Icons.storefront,
            color: p.action,
            size: 20,
          ),
        ],
      ),
    );
  }
}
