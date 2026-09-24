import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/models/library_vibe.dart';
import '../../core/motion.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/stage.dart';
import '../connections/heart_screen.dart';
import '../gallery/gallery_screen.dart';
import '../library_vibes/conversation_library_screen.dart';
import '../library_vibes/library_vibes_repository.dart';
import 'event_finder_screen.dart';
import 'event_screen.dart';
import 'events_providers.dart';

/// **Le générique de fin de soirée** (Jay, 2026-09-24 : *« fais-le, fais-moi
/// rêver, carte blanche »*).
///
/// Une story plein écran, sur la scène de nuit, qui défile seule — cinq
/// images, comme un générique :
///
/// 1. **« C'était Goat. »** — le rond, le jour, la durée ;
/// 2. **les chiffres** — présents, Vibes, rencontres, nouveaux amis, qui
///    montent en comptant ;
/// 3. **le Drop** — ce que vous avez vécu, qui zoome lentement ;
/// 4. **les gens** — en constellation autour de moi, et mes vraies rencontres ;
/// 5. **« Ta soirée est gardée »** — revoir le Drop, la galerie, les
///    rencontres.
///
/// Toucher à droite avance, à gauche recule ; la croix ferme. Tout ce qui
/// s'affiche est LU (récap, présents, Drop) — rien n'est écrit.
///
/// Ouvert : quand la soirée se ferme sous mes yeux (`EventScreen`), par la
/// notification « c'est fini » (`recap:<id>`), et par « Revivre la soirée ».
class EventRecapScreen extends ConsumerStatefulWidget {
  const EventRecapScreen({super.key, required this.eventId});

  final String eventId;

  @override
  ConsumerState<EventRecapScreen> createState() => _EventRecapScreenState();
}

class _EventRecapScreenState extends ConsumerState<EventRecapScreen>
    with SingleTickerProviderStateMixin {
  static const _count = 5;

  /// Le temps d'une image. La dernière ne défile pas : elle attend un geste.
  static const _slide = Duration(milliseconds: 5600);

  late final _timer = AnimationController(vsync: this, duration: _slide)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    })
    ..forward();

  var _index = 0;

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i < 0 || i >= _count) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _index = i);
    _timer.reset();
    if (i < _count - 1) _timer.forward();
  }

  void _next() => _go(_index + 1);
  void _previous() => _go(_index - 1);

  @override
  Widget build(BuildContext context) {
    final event = ref.watch(eventByIdProvider(widget.eventId));
    final recap = ref.watch(eventRecapProvider(widget.eventId)).value;
    final people =
        ref.watch(eventPeopleProvider(widget.eventId)).value ??
        const <EventPerson>[];
    final vibes = event == null
        ? const <LibraryVibe>[]
        : ref.watch(conversationLibraryProvider(event.conversationId)).value ??
              const <LibraryVibe>[];

    final Widget slide;
    if (event == null) {
      slide = const Center(child: CircularProgressIndicator());
    } else {
      slide = switch (_index) {
        0 => _Opening(event: event),
        1 => _Numbers(recap: recap),
        2 => _DropMosaic(vibes: vibes),
        3 => _People(people: people, recap: recap),
        _ => _Ending(event: event, recap: recap),
      };
    }

    return NightStage(
      intensity: 1.6,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              // Toucher : à gauche on recule, ailleurs on avance. Sous le
              // contenu, pour que les boutons de la dernière image gardent la
              // main.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final w = MediaQuery.sizeOf(context).width;
                    if (d.localPosition.dx < w / 3) {
                      _previous();
                    } else {
                      _next();
                    }
                  },
                ),
              ),
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      NeoSpace.lg,
                      NeoSpace.sm,
                      NeoSpace.xs,
                      0,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _StoryBars(
                            count: _count,
                            index: _index,
                            progress: _timer,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: IgnorePointer(
                      // Seule la dernière image a des boutons.
                      ignoring: _index < _count - 1,
                      child: AnimatedSwitcher(
                        duration: NeoMotion.ample,
                        switchInCurve: NeoMotion.enter,
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: ScaleTransition(
                            scale: Tween(begin: 0.96, end: 1.0).animate(a),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(_index),
                          child: slide,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Les barres de story : pleines derrière, qui se remplit, vides devant.
class _StoryBars extends StatelessWidget {
  const _StoryBars({
    required this.count,
    required this.index,
    required this.progress,
  });

  final int count;
  final int index;
  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) => Row(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NeoRadius.pill),
                child: SizedBox(
                  height: 3.5,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: p.ink.withValues(alpha: 0.18)),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: i < index
                            ? 1
                            : i == index
                            ? (i == count - 1 ? 1 : progress.value)
                            : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: p.signatureCourte,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Une image : son contenu au centre, avec de l'air.
class _Slide extends StatelessWidget {
  const _Slide({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NeoSpace.xxl - 4),
    child: Center(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

class _Kicker extends StatelessWidget {
  const _Kicker(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    textAlign: TextAlign.center,
    style: TextStyle(
      color: context.palette.inkMuted,
      fontSize: 12.5,
      letterSpacing: 2.2,
      fontWeight: FontWeight.w600,
    ),
  );
}

// ─── 1. « C'était Goat. » ────────────────────────────────────────────────

class _Opening extends StatelessWidget {
  const _Opening({required this.event});

  final NeoEvent event;

  String _duration() {
    final start = event.openedAt ?? event.startsAt;
    final end = event.closedAt ?? DateTime.now();
    final d = end.difference(start);
    if (d.inMinutes < 60) return '${d.inMinutes} min de soirée';
    final m = d.inMinutes % 60;
    return '${d.inHours} h${m == 0 ? '' : ' ${m.toString().padLeft(2, '0')}'} '
        'de soirée';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Slide(
      children: [
        const MyStageHalo(size: 180),
        const SizedBox(height: NeoSpace.section + 8),
        const _Kicker('C\'était'),
        const SizedBox(height: NeoSpace.sm),
        StageTitle(event.venueName ?? event.title, gradient: true),
        if (event.venueName != null) ...[
          const SizedBox(height: NeoSpace.xs),
          Text(event.title, style: TextStyle(color: p.ink, fontSize: 17)),
        ],
        const SizedBox(height: NeoSpace.lg),
        Text(
          '${dayAndTime(event.startsAt)} · ${_duration()}',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.inkMuted, fontSize: 15),
        ),
      ],
    );
  }
}

// ─── 2. Les chiffres ─────────────────────────────────────────────────────

class _Numbers extends StatelessWidget {
  const _Numbers({required this.recap});

  final EventRecap? recap;

  @override
  Widget build(BuildContext context) {
    final r = recap;
    final items = r == null
        ? const <(int, String, String)>[]
        : [
            (r.presentCount, 'présent', 'présents'),
            (r.vibeCount, 'Vibe', 'Vibes'),
            (r.metCount, 'vraie rencontre', 'vraies rencontres'),
            (r.newFriendCount, 'nouvel ami', 'nouveaux amis'),
          ];
    return _Slide(
      children: [
        const _Kicker('Ta soirée'),
        const SizedBox(height: NeoSpace.sm),
        const StageTitle('en chiffres'),
        const SizedBox(height: NeoSpace.section),
        if (r == null)
          const CircularProgressIndicator()
        else
          for (final (i, (n, one, many)) in items.indexed)
            _Counter(value: n, label: n > 1 ? many : one, delay: i * 320),
      ],
    );
  }
}

/// Un chiffre qui monte en comptant, après un court délai.
class _Counter extends StatefulWidget {
  const _Counter({
    required this.value,
    required this.label,
    required this.delay,
  });

  final int value;
  final String label;
  final int delay;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var _shown = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedOpacity(
      duration: NeoMotion.normal,
      opacity: _shown ? 1 : 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NeoSpace.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: _shown ? widget.value.toDouble() : 0),
              duration: const Duration(milliseconds: 1100),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => ShaderMask(
                shaderCallback: (r) => p.signature.createShader(r),
                child: Text(
                  '${v.round()}',
                  style: TextStyle(
                    fontFamily: NeoType.display,
                    fontWeight: FontWeight.w600,
                    fontSize: 54,
                    height: 1,
                    color: p.ink,
                  ),
                ),
              ),
            ),
            const SizedBox(width: NeoSpace.md),
            Text(
              widget.label,
              style: TextStyle(
                fontFamily: NeoType.display,
                fontSize: 20,
                color: p.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 3. Le Drop ──────────────────────────────────────────────────────────

class _DropMosaic extends StatelessWidget {
  const _DropMosaic({required this.vibes});

  final List<LibraryVibe> vibes;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shown = [...vibes]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return _Slide(
      children: [
        const _Kicker('Le Drop'),
        const SizedBox(height: NeoSpace.sm),
        const StageTitle('Ce que vous\navez vécu'),
        const SizedBox(height: NeoSpace.xl),
        if (shown.isEmpty)
          Text(
            'Pas de Vibe ce soir-là.\nLa prochaine fois, c\'est toi qui ouvres '
            'le bal ?',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.inkMuted, fontSize: 15, height: 1.4),
          )
        else
          // Un lent zoom : la mosaïque respire, comme un souvenir qui revient.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: 1.06),
            duration: const Duration(seconds: 6),
            curve: Curves.easeOut,
            builder: (context, s, child) =>
                Transform.scale(scale: s, child: child),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: NeoSpace.sm,
              crossAxisSpacing: NeoSpace.sm,
              childAspectRatio: 9 / 16,
              children: [
                for (final v in shown.take(6))
                  LibraryVibeTile(vibe: v, onRefresh: () {}),
              ],
            ),
          ),
        if (shown.length > 6) ...[
          const SizedBox(height: NeoSpace.md),
          Text(
            '+ ${shown.length - 6} autres dans le Drop',
            style: TextStyle(color: p.inkMuted),
          ),
        ],
      ],
    );
  }
}

// ─── 4. Les gens ─────────────────────────────────────────────────────────

class _People extends ConsumerWidget {
  const _People({required this.people, required this.recap});

  final List<EventPerson> people;
  final EventRecap? recap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final me = ref.watch(currentUserIdProvider);
    final others = [
      for (final x in people)
        if (x.userId != me) x,
    ];
    final ring = others.take(10).toList();
    final friends = [
      for (final x in others)
        if (recap?.friendsPresent.contains(x.userId) ?? false) x.chatName,
    ];
    final met = recap?.metCount ?? 0;
    return _Slide(
      children: [
        const _Kicker('Les gens'),
        const SizedBox(height: NeoSpace.sm),
        const StageTitle('Ils étaient là'),
        const SizedBox(height: NeoSpace.lg),
        SizedBox(
          height: 280,
          width: 280,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const MyStageHalo(size: 92, breathing: false),
              for (final (i, x) in ring.indexed)
                _Orbiting(index: i, total: ring.length, person: x),
            ],
          ),
        ),
        if (others.length > ring.length)
          Text(
            '+ ${others.length - ring.length}',
            style: TextStyle(color: p.inkMuted),
          ),
        const SizedBox(height: NeoSpace.md),
        if (friends.isNotEmpty)
          Text(
            'Avec ${_list(friends)}.',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.ink, fontSize: 16),
          ),
        if (met > 0) ...[
          const SizedBox(height: NeoSpace.sm),
          Text(
            'Tu en as vraiment croisé $met. Tu as trois jours pour les '
            'retrouver.',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.inkMuted, fontSize: 14.5, height: 1.4),
          ),
        ],
      ],
    );
  }

  static String _list(List<String> names) {
    if (names.length == 1) return names.first;
    final head = names.take(3).toList();
    final rest = names.length - head.length;
    if (rest > 0) return '${head.join(', ')} et $rest autres';
    return '${head.sublist(0, head.length - 1).join(', ')} et ${head.last}';
  }
}

/// Un visage sur l'orbite, qui arrive à son tour.
class _Orbiting extends StatelessWidget {
  const _Orbiting({
    required this.index,
    required this.total,
    required this.person,
  });

  final int index;
  final int total;
  final EventPerson person;

  @override
  Widget build(BuildContext context) {
    final angle = -math.pi / 2 + 2 * math.pi * index / math.max(total, 1);
    const radius = 112.0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 500 + index * 130),
      curve: NeoMotion.spring,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(
          math.cos(angle) * radius * t,
          math.sin(angle) * radius * t,
        ),
        child: Opacity(opacity: t.clamp(0, 1), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: context.palette.signatureCourte,
        ),
        child: Avatar(
          stored: person.avatarUrl,
          radius: 22,
          fallback: Text(person.chatName.characters.first.toUpperCase()),
        ),
      ),
    );
  }
}

// ─── 5. La fin ───────────────────────────────────────────────────────────

class _Ending extends StatelessWidget {
  const _Ending({required this.event, required this.recap});

  final NeoEvent event;
  final EventRecap? recap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final met = recap?.metCount ?? 0;
    return _Slide(
      children: [
        const MyStageHalo(size: 120),
        const SizedBox(height: NeoSpace.section),
        const StageTitle('Ta soirée\nest gardée.', gradient: true),
        const SizedBox(height: NeoSpace.md),
        Text(
          'Dans ta galerie : où, quand, avec qui.\nLe Drop reste ouvert '
          'cinq jours.',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.inkMuted, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: NeoSpace.section),
        GlowButton(
          label: 'Revoir le Drop',
          icon: Icons.photo_library_rounded,
          // Remplace le générique par la soirée : ouvert depuis une
          // notification, un simple retour ramènerait à l'accueil.
          onPressed: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => EventScreen(eventId: event.id)),
          ),
        ),
        const SizedBox(height: NeoSpace.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: NeoSpace.sm,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const GalleryScreen()),
              ),
              child: const Text('Ma galerie'),
            ),
            if (met > 0)
              TextButton(
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const HeartScreen()),
                ),
                child: const Text('Mes rencontres'),
              ),
          ],
        ),
      ],
    );
  }
}
