import 'dart:async';

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
import 'map_tiles.dart';

/// **La carte** (étape 5 du programme du 2026-09-21) : les soirées à portée
/// autour de moi, et — dans l'événement où je suis — ses points chauds.
///
/// ## 🔴 Refaite le 2026-09-22, sur les captures de Jay
///
/// Ce que montraient ses quatre captures et ce qui change :
///
/// | Défaut | Correction |
/// |---|---|
/// | carte **claire** dans une app sombre | fond OpenStreetMap **assombri chez nous** selon le thème ([MapTiles]) — la tentative CARTO du matin exigeait une clé |
/// | tout **flou** | on demande les tuiles du niveau au-dessus et on les dessine sur la même surface (OSM ne sert pas de @2x) |
/// | le point affiché **à ~2 km** de l'endroit réel (14:39) | la position était lue **une seule fois** à l'ouverture et jamais corrigée : elle est maintenant relue toutes les 15 s et au recentrage, et l'écran **dit d'où vient le point** (`_libelleFix`) |
/// | motifs géants puis **gris vide** en zoomant | le zoom est **borné** ([MapTiles.maxZoom]) : on ne peut plus dépasser le dernier niveau qui existe |
/// | un viseur `my_location` posé sur la carte | un **point avec son halo d'incertitude** — ce que l'appareil sait vraiment |
/// | la mention « © OpenStreetMap » sous la barre système | attribution remontée dans la zone sûre, sur un fond qui la détache |
///
/// Et un bouton **recentrer**, qui manquait : une fois perdu, on ne revenait
/// chez soi qu'en refermant l'écran.
///
/// ⚠️ Toujours un fond gratuit sans contrat (RAPPELS #157). Rien n'est envoyé
/// au serveur depuis cet écran ; il lit les mêmes vues que la liste.
class EventsMapScreen extends ConsumerStatefulWidget {
  const EventsMapScreen({super.key, this.eventId});

  /// Un événement à centrer (ses points chauds) ; nul = autour de moi.
  final String? eventId;

  @override
  ConsumerState<EventsMapScreen> createState() => _EventsMapScreenState();
}

class _EventsMapScreenState extends ConsumerState<EventsMapScreen> {
  final _map = MapController();
  CoarseFix? _me;
  DateTime? _meAt;
  Timer? _suivi;

  /// ⚠️ **Posé une seule fois, au premier build utile.** Recalculer le centre
  /// à chaque reconstruction ramènerait la carte de force sous le doigt dès
  /// qu'une position arrive ou qu'un point chaud bouge.
  LatLng? _centreInitial;

  /// 🔴 **La carte lisait la position UNE FOIS, à l'ouverture, et ne la
  /// corrigeait jamais** — relevé sur la capture de Jay du 2026-09-22 (14:39),
  /// où le point affiché était à ~2 km de l'endroit réel.
  ///
  /// Quinze secondes : assez pour qu'un GPS froid ait le temps de répondre
  /// après un premier repli sur le réseau, assez peu pour qu'on ne reste pas
  /// planté sur un point faux en regardant l'écran.
  static const _rythmeDeSuivi = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _relis(recentre: true);
    _suivi = Timer.periodic(_rythmeDeSuivi, (_) => _relis());
  }

  @override
  void dispose() {
    _suivi?.cancel();
    super.dispose();
  }

  Future<void> _relis({bool recentre = false}) async {
    final fix = await ref.read(coarseLocationProvider).current();
    if (!mounted || fix == null) return;
    setState(() {
      _me = fix;
      _meAt = DateTime.now();
    });
    // La position arrive après coup : si la carte s'est ouverte sur le centre
    // de secours, on la ramène — une fois, au premier relevé seulement.
    if (recentre && _centreInitial == null) {
      _map.move(LatLng(fix.latitude, fix.longitude), MapTiles.initialZoom);
    }
  }

  /// Recentrer **relit** d'abord : c'est le geste de quelqu'un qui trouve que
  /// le point est faux, pas celui de quelqu'un qui veut revoir le même point.
  Future<void> _recentrer() async {
    await _relis();
    final me = _me;
    if (me == null || !mounted) return;
    _map.move(LatLng(me.latitude, me.longitude), MapTiles.initialZoom);
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
    _centreInitial ??= event?.lat != null
        ? LatLng(event!.lat!, event.lon!)
        : spots.isNotEmpty
        ? LatLng(spots.first.lat, spots.first.lon)
        : me != null
        ? LatLng(me.latitude, me.longitude)
        : null;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(event?.title ?? 'Autour de moi'),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _centreInitial ?? const LatLng(50.63, 3.06),
              initialZoom: MapTiles.initialZoom,
              // 🔴 **Les deux bornes qui manquaient.** Voir [MapTiles.maxZoom] :
              // au-delà, aucune tuile n'existe et le moteur agrandissait la
              // dernière — flou, puis motifs géants, puis gris vide.
              minZoom: MapTiles.minZoom,
              maxZoom: MapTiles.maxZoom,
              // On ne sort pas du monde : sans ça, un doigt trop rapide laisse
              // la carte dans le vide, sans moyen de revenir.
              cameraConstraint: CameraConstraint.contain(
                bounds: LatLngBounds(
                  const LatLng(-85, -180),
                  const LatLng(85, 180),
                ),
              ),
              // Le fond entre deux tuiles suit le thème : une tuile qui arrive
              // sur du blanc, la nuit, fait un éclair.
              backgroundColor: p.ground,
              interactionOptions: const InteractionOptions(
                // Pas de rotation : une carte de travers ne sert à personne ici
                // et s'attrape par accident à deux doigts.
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              MapTiles.layer(context, dark: p.isDark),
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
                  // ⚠️ **Le halo d'incertitude, en MÈTRES.** L'appareil ne sait
                  // pas où il est au mètre près (`accuracy` : 21 m au mieux,
                  // 100 m et plus en intérieur, relevé du 2026-09-22). Un point
                  // net sans halo affirme une précision qu'on n'a pas.
                  if (me != null)
                    CircleMarker(
                      point: LatLng(me.latitude, me.longitude),
                      radius: me.accuracy,
                      useRadiusInMeter: true,
                      color: p.cool.withValues(alpha: 0.12),
                      borderColor: p.cool.withValues(alpha: 0.4),
                      borderStrokeWidth: 1,
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (me != null)
                    Marker(
                      point: LatLng(me.latitude, me.longitude),
                      width: 18,
                      height: 18,
                      child: _PointMoi(couleur: p.cool, bord: p.ground),
                    ),
                  for (final e in nearby.value ?? const <NearbyEvent>[])
                    Marker(
                      point: LatLng(e.lat, e.lon),
                      width: 140,
                      height: 52,
                      // L'épingle pointe le lieu : son bas doit tomber sur le
                      // point, pas son milieu.
                      alignment: Alignment.topCenter,
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
              bottom: 40,
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
          if (me != null)
            Positioned(
              right: 16,
              bottom: 48,
              child: FloatingActionButton.small(
                heroTag: 'recentrer',
                onPressed: _recentrer,
                backgroundColor: p.surface,
                foregroundColor: p.ink,
                child: const Icon(Icons.my_location),
              ),
            ),
          // ⚠️ **L'attribution est obligatoire, donc elle doit être LISIBLE.**
          // Elle était collée en bas à gauche, à moitié sous la barre de
          // navigation du téléphone (capture du 2026-09-22). `SafeArea` la
          // remonte, et un fond la détache de la carte.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  margin: const EdgeInsets.only(left: 8, bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: p.ground.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    me == null
                        ? '© OpenStreetMap'
                        : '© OpenStreetMap · ${_libelleFix(me, _meAt)}',
                    style: TextStyle(fontSize: 10, color: p.inkMuted),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// **D'où vient le point, et ce qu'il vaut** — écrit à côté de l'attribution.
///
/// 🔴 **Ajouté le 2026-09-22, sur une capture de Jay** : le point affiché
/// était à ~2 km de l'endroit réel, et **rien à l'écran ne permettait de dire
/// pourquoi**. Un point faux et un point juste avaient exactement la même
/// apparence — c'est le défaut d'instrument que `CLAUDE.md` interdit de
/// laisser passer.
///
/// Les trois mots disent chacun une cause différente :
/// - **GPS** ([FixSource.best]) : satellites + Wi-Fi + antennes ;
/// - **réseau** ([FixSource.network]) : Wi-Fi et antennes **sans** satellites
///   — c'est le palier qui se trompe de plusieurs centaines de mètres quand la
///   base de données des bornes Wi-Fi est fausse ;
/// - **mémoire** ([FixSource.lastKnown]) : un point d'il y a jusqu'à 5 min.
///
/// L'incertitude est celle **qu'annonce l'appareil**, pas une estimation de
/// notre part : un « ± 20 m » sur un point faux de 2 km est en soi le
/// diagnostic.
String _libelleFix(CoarseFix fix, DateTime? at) {
  final source = switch (fix.source) {
    FixSource.best => 'GPS',
    FixSource.network => 'réseau',
    FixSource.lastKnown => 'mémoire',
  };
  final age = at == null
      ? ''
      : ' · ${DateTime.now().difference(at).inSeconds} s';
  return '$source ± ${fix.accuracy.round()} m$age';
}

/// Ma position : un point plein cerclé de la couleur du fond, pour rester
/// visible sur une carte claire **comme** sombre.
class _PointMoi extends StatelessWidget {
  const _PointMoi({required this.couleur, required this.bord});
  final Color couleur;
  final Color bord;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: couleur,
      shape: BoxShape.circle,
      border: Border.all(color: bord, width: 3),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4),
      ],
    ),
  );
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
          Icon(
            event.kind == EventKind.open ? Icons.celebration : Icons.storefront,
            color: p.action,
            size: 22,
          ),
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
        ],
      ),
    );
  }
}
