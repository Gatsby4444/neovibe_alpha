import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/stage.dart';
import 'create_event_screen.dart';
import 'event_screen.dart';
import 'events_map_screen.dart';
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

class _EventFinderScreenState extends ConsumerState<EventFinderScreen> {
  /// Le radar dure au moins ce temps : trouvé en 200 ms, il n'aurait pas eu
  /// le temps de dire ce qu'il fait.
  static const _minRadar = Duration(milliseconds: 2200);

  late final _started = DateTime.now();
  var _radarDone = false;

  /// La soirée choisie à la main parmi celles à portée ; nulle = la plus
  /// proche.
  String? _chosenId;

  @override
  void initState() {
    super.initState();
    // Une liste fraîche : celle du cache peut dater d'un autre endroit.
    Future.microtask(() => ref.invalidate(nearbyEventsProvider));
    Future<void>.delayed(_minRadar, () {
      if (mounted) setState(() => _radarDone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final nearby = ref.watch(nearbyEventsProvider);
    final searching =
        !_radarDone ||
        nearby.isLoading ||
        DateTime.now().difference(_started) < _minRadar;

    final List<NearbyEvent> reachable;
    final List<NearbyEvent> far;
    final Object? error = nearby.hasError ? nearby.error : null;
    final list = nearby.value ?? const <NearbyEvent>[];
    reachable = [
      for (final e in list)
        if (e.withinReach) e,
    ]..sort((a, b) => a.distanceM.compareTo(b.distanceM));
    far = [
      for (final e in list)
        if (!e.withinReach) e,
    ]..sort((a, b) => a.distanceM.compareTo(b.distanceM));

    NearbyEvent? found;
    if (reachable.isNotEmpty) {
      found = reachable.firstWhere(
        (e) => e.id == _chosenId,
        orElse: () => reachable.first,
      );
    }

    return NightStage(
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
                    : found != null
                    ? VenueFoundView(
                        event: found,
                        others: [
                          for (final e in reachable)
                            if (e.id != found.id) e,
                        ],
                        onChoose: (e) => setState(() => _chosenId = e.id),
                        onJoined: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => EventScreen(eventId: found!.id),
                          ),
                        ),
                      )
                    : _NothingHere(
                        nearest: far.isEmpty ? null : far.first,
                        noPosition: error is StateError,
                        onRetry: () {
                          setState(() => _radarDone = false);
                          ref.invalidate(nearbyEventsProvider);
                          Future<void>.delayed(_minRadar, () {
                            if (mounted) setState(() => _radarDone = true);
                          });
                        },
                      ),
              ),
            ],
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
                      v.withinReach ? 'Tu es au' : 'La soirée',
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
                        if (!v.withinReach) 'à ${v.distanceM} m',
                      ].join(' · '),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.ink, fontSize: 16),
                    ),
                    if (!v.withinReach) ...[
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
            onPressed: v.withinReach ? _join : null,
          ),
        ],
      ),
    );
  }
}

class _NothingHere extends StatelessWidget {
  const _NothingHere({
    required this.nearest,
    required this.noPosition,
    required this.onRetry,
  });

  final NearbyEvent? nearest;
  final bool noPosition;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final n = nearest;
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
                          : n == null
                          ? 'Lance la tienne avec tes amis, ou regarde la '
                                'carte.'
                          : 'La plus proche : ${n.venueName ?? n.title}, '
                                'à ${n.distanceM} m.',
                    ),
                    const SizedBox(height: NeoSpace.lg),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: NeoSpace.sm,
                      children: [
                        ActionChip(
                          avatar: Icon(Icons.refresh_rounded, color: p.ink),
                          label: const Text('Chercher encore'),
                          onPressed: onRetry,
                        ),
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
          GlowButton(
            label: 'Créer une soirée',
            icon: Icons.add_rounded,
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const CreateEventScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
