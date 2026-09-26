import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/stage.dart';
import 'event_deck.dart';
import 'event_screen.dart';
import 'events_map_screen.dart';
import '../proximity/geo/live_position_keeper.dart';
import 'events_providers.dart';
import 'events_screen.dart';

/// **« Trouver ma soirée »** — le radar de l'arrivée en soirée (test validé
/// par Jay le 2026-09-24), branché sur les vraies soirées autour de moi.
///
/// Il lit `nearbyEventsProvider` (la position, puis `nearby_events` côté
/// serveur) et retient **la plus proche à portée**. Rejoindre passe par
/// [rejoindreEvenement], le geste unique de toute l'app : c'est le serveur qui
/// juge la distance.
class EventFinderScreen extends ConsumerStatefulWidget {
  const EventFinderScreen({super.key});

  @override
  ConsumerState<EventFinderScreen> createState() => _EventFinderScreenState();
}

class _EventFinderScreenState extends ConsumerState<EventFinderScreen>
    with SingleTickerProviderStateMixin {
  /// Le radar dure au moins ce temps : trouvé en 200 ms, il n'aurait pas eu
  /// le temps de dire ce qu'il fait.
  static const _minRadar = Duration(milliseconds: 2200);

  /// Le radar a tourné son temps minimum. **La seule horloge de l'écran.**
  ///
  /// ⚠️ **Il y en avait deux jusqu'au 2026-09-25** : ce drapeau, et un
  /// `late final _started = DateTime.now()` relu dans `build`. Un `late` avec
  /// initialiseur s'évalue au premier ACCÈS — le premier `build`, quelques
  /// millisecondes APRÈS le départ du minuteur. Quand le minuteur sonnait,
  /// moins de [_minRadar] s'étaient écoulées « selon `_started` » : l'écran
  /// cherchait encore, et si la liste était déjà arrivée, plus rien ne le
  /// redessinait. **Le radar tournait pour toujours** (Jay : 80 minutes,
  /// soirée à 3 m). Reproduit : `test/event_finder_test.dart`.
  var _radarDone = false;

  /// **La révélation** (Jay, 2026-09-25) : ma photo s'enfonce dans le fond,
  /// les ondes s'effacent, puis les cartes des soirées montent.
  late final _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final Animation<double> _sink = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0, 0.5, curve: Curves.easeInCubic),
  );
  late final Animation<double> _rise = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0.3, 1),
  );

  @override
  void initState() {
    super.initState();
    // Une liste fraîche : celle du cache peut dater d'un autre endroit.
    Future.microtask(() => ref.invalidate(nearbyEventsProvider));
    _startRadar();
  }

  void _startRadar() {
    Future<void>.delayed(_minRadar, () {
      if (mounted) setState(() => _radarDone = true);
    });
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = ref.watch(nearbyEventsProvider);
    final searching = !_radarDone || nearby.isLoading;
    final Object? error = nearby.hasError ? nearby.error : null;
    // Toutes les soirées autour, de la plus proche à la plus lointaine :
    // celles à portée viennent donc d'elles-mêmes en premier.
    final events = [...?nearby.value]
      ..sort((a, b) => a.distanceM.compareTo(b.distanceM));

    // Trouvé : la révélation part, une fois.
    if (!searching && events.isNotEmpty && _reveal.isDismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _reveal.isDismissed) _reveal.forward();
      });
    }

    // Suivie en continu tant que l'écran est regardé : la distance aux
    // soirées bouge en temps réel (2026-09-26).
    return LivePositionKeeper(
      child: NightStage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                Expanded(
                  child: searching
                      ? const _Searching()
                      : events.isEmpty
                      ? _NothingHere(
                          noPosition: error is StateError,
                          onRetry: () {
                            setState(() => _radarDone = false);
                            ref.invalidate(nearbyEventsProvider);
                            _startRadar();
                          },
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            EventDeck(
                              events: events,
                              entrance: _rise,
                              onJoined: (e) =>
                                  Navigator.of(context).pushReplacement(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          EventScreen(eventId: e.id),
                                    ),
                                  ),
                            ),
                            // Ma photo, qui s'enfonce dans le fond.
                            AnimatedBuilder(
                              animation: _sink,
                              builder: (context, _) {
                                final t = _sink.value;
                                if (t >= 1) return const SizedBox.shrink();
                                return IgnorePointer(
                                  child: Opacity(
                                    opacity: 1 - t,
                                    child: Transform.translate(
                                      offset: Offset(0, -60 * t),
                                      child: Transform.scale(
                                        scale: 1 - 0.7 * t,
                                        child: ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(
                                            sigmaX: 14 * t,
                                            sigmaY: 14 * t,
                                          ),
                                          child: const _Searching(),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mon rond : ma photo de profil dans le halo (l'initiale, à défaut).
class MyStageHalo extends ConsumerWidget {
  const MyStageHalo({super.key, required this.size, this.breathing = true});

  final double size;
  final bool breathing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).value;
    final initial = me == null || me.displayName.isEmpty
        ? ''
        : me.displayName.characters.first.toUpperCase();
    return StageHalo(
      size: size,
      breathing: breathing,
      child: me?.avatarUrl == null
          ? HaloInitial(initial, size: size)
          : Avatar(
              stored: me!.avatarUrl,
              radius: size / 2,
              fallback: HaloInitial(initial, size: size),
            ),
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: NeoSpace.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 300,
            child: Center(
              child: SonarRings(active: true, child: MyStageHalo(size: 120)),
            ),
          ),
          StageTitle('On cherche\nta soirée…'),
          SizedBox(height: NeoSpace.md),
          _Lead('Avec ta position, et les téléphones autour de toi.'),
        ],
      ),
    );
  }
}

class _Lead extends StatelessWidget {
  const _Lead(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: context.palette.inkMuted,
      fontSize: 16,
      height: 1.4,
    ),
  );
}

/// **« Tu es au … »** — la soirée trouvée, et le geste pour y entrer.
///
/// Sert DEUX chemins, pour qu'ils ne divergent pas : le radar (ci-dessus), et
/// l'écran d'une soirée que je n'ai pas encore rejointe (`EventScreen`,
/// arrivé par la liste ou la carte).
class VenueFoundView extends ConsumerStatefulWidget {
  const VenueFoundView({
    super.key,
    required this.event,
    this.others = const [],
    this.onChoose,
    this.onJoined,
  });

  final NearbyEvent event;

  /// Les autres soirées à portée, à choisir à la main.
  final List<NearbyEvent> others;
  final ValueChanged<NearbyEvent>? onChoose;

  /// Appelé une fois entré ; nul = l'écran appelant se met à jour seul.
  final VoidCallback? onJoined;

  @override
  ConsumerState<VenueFoundView> createState() => _VenueFoundViewState();
}

class _VenueFoundViewState extends ConsumerState<VenueFoundView> {
  var _busy = false;

  Future<void> _join() async {
    setState(() => _busy = true);
    unawaited(HapticFeedback.heavyImpact());
    final ok = await rejoindreEvenement(context, ref, widget.event.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onJoined?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final v = widget.event;
    final place = v.venueName ?? v.title;
    final n = v.presentCount;
    // La distance de L'INSTANT (2026-09-26) : elle bouge quand on marche.
    final d = liveDistanceTo(ref, v);
    final ici = v.withinReachAt(d);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.xxl - 4,
        0,
        NeoSpace.xxl - 4,
        NeoSpace.xl,
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      height: 240,
                      child: Center(
                        child: SonarRings(
                          active: false,
                          child: MyStageHalo(size: 120),
                        ),
                      ),
                    ),
                    Text(
                      ici ? 'Tu es au' : 'La soirée',
                      style: TextStyle(color: p.inkMuted, fontSize: 16),
                    ),
                    const SizedBox(height: NeoSpace.xs),
                    StageTitle(place, gradient: true),
                    const SizedBox(height: NeoSpace.sm),
                    Text(
                      [
                        if (v.venueName != null) v.title,
                        n == 0
                            ? 'personne encore'
                            : '$n présent${n > 1 ? 's' : ''}',
                        if (!ici) 'à $d m',
                      ].join(' · '),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.ink, fontSize: 16),
                    ),
                    if (!ici) ...[
                      const SizedBox(height: NeoSpace.md),
                      const _Lead(
                        'Approche-toi : on rejoint une soirée en étant sur '
                        'place.',
                      ),
                    ],
                    if (widget.others.isNotEmpty) ...[
                      const SizedBox(height: NeoSpace.xl),
                      Text(
                        'Pas celle-là ?',
                        style: TextStyle(color: p.inkMuted, fontSize: 13),
                      ),
                      const SizedBox(height: NeoSpace.sm),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: NeoSpace.sm,
                        runSpacing: NeoSpace.sm,
                        children: [
                          for (final o in widget.others)
                            ActionChip(
                              label: Text(o.venueName ?? o.title),
                              onPressed: () => widget.onChoose?.call(o),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          GlowButton(
            label: 'Rejoindre la soirée',
            icon: Icons.celebration_rounded,
            busy: _busy,
            onPressed: ici ? _join : null,
          ),
        ],
      ),
    );
  }
}

class _NothingHere extends StatelessWidget {
  // ⚠️ Plus de « la plus proche : … » ici (2026-09-25) : le paquet montre
  // TOUTES les soirées autour, à portée ou non. Cet écran ne dit donc plus
  // que « rien à moins de 2 km ».
  const _NothingHere({required this.noPosition, required this.onRetry});

  final bool noPosition;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.xxl - 4,
        0,
        NeoSpace.xxl - 4,
        NeoSpace.xl,
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MyStageHalo(size: 110, breathing: false),
                    const SizedBox(height: NeoSpace.section),
                    StageTitle(
                      noPosition
                          ? 'Où es-tu ?'
                          : 'Pas de soirée\nici pour l\'instant',
                    ),
                    const SizedBox(height: NeoSpace.md),
                    _Lead(
                      noPosition
                          ? 'Active la localisation pour trouver la soirée '
                                'où tu es.'
                          : 'Rien autour de toi pour l\'instant. Réessaie '
                                'une fois dans la soirée, ou regarde la carte.',
                    ),
                    const SizedBox(height: NeoSpace.lg),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: NeoSpace.sm,
                      children: [
                        ActionChip(
                          avatar: Icon(Icons.map_outlined, color: p.ink),
                          label: const Text('La carte'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const EventsMapScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Pas de « Créer une soirée » ici (Jay, 2026-09-24) : quelqu'un qui
          // arrive cherche SA soirée — on lui propose de réessayer. Créer
          // reste possible depuis l'écran Événements (« + »).
          GlowButton(
            label: 'Chercher encore',
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
