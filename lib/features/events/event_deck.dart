import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/moderation.dart';
import '../../core/models/event.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/report_sheet.dart';
import '../../core/widgets/stage.dart';
import '../connections/connections_repository.dart';
import 'event_poster.dart';
import 'events_providers.dart';
import 'events_screen.dart';

/// **Le paquet des soirées autour de moi** (Jay, 2026-09-25) — ce que le
/// radar montre quand il a trouvé : une carte par soirée, **de la plus
/// proche à la plus lointaine**, qu'on fait glisser.
///
/// ### L'effet différé
///
/// Chaque couche d'une carte glisse à SA vitesse (« une dissociation entre
/// les éléments et leur vitesse de swipe, ce qui crée un effet différé ») :
///
/// | Couche | Décalage par carte d'écart |
/// |---|---|
/// | la carte (cadre) | celui du `PageView` — la référence |
/// | l'affiche | −[_posterLag] : elle **traîne** derrière son cadre |
/// | le titre | +[_titleLead] : il **devance** légèrement |
/// | les infos | +[_infoLead], et s'effacent : elles arrivent en dernier |
///
/// Le fond prend la **couleur de l'affiche** montrée et glisse d'une
/// couleur à l'autre ; chaque carte posée donne une petite vibration.
///
/// ⚠️ Ne décide rien : l'ordre vient du serveur (`nearby_events`, par
/// distance), « rejoindre » passe par [rejoindreEvenement] — le serveur juge
/// la distance. Les amis montrés sont ceux que le serveur a choisis (MES
/// amis, jamais un inconnu).
class EventDeck extends ConsumerStatefulWidget {
  const EventDeck({
    super.key,
    required this.events,
    required this.entrance,
    required this.onJoined,
  });

  /// Déjà triées, de la plus proche à la plus lointaine.
  final List<NearbyEvent> events;

  /// 0 → 1 : la montée des cartes, pilotée par la révélation du radar.
  final Animation<double> entrance;
  final ValueChanged<NearbyEvent> onJoined;

  @override
  ConsumerState<EventDeck> createState() => _EventDeckState();
}

const _posterLag = 46.0;
const _titleLead = 34.0;
const _infoLead = 78.0;

class _EventDeckState extends ConsumerState<EventDeck> {
  final _pages = PageController(viewportFraction: 0.82);
  var _page = 0.0;
  var _index = 0;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _pages.addListener(() {
      final p = _pages.page ?? 0;
      final i = p.round().clamp(0, widget.events.length - 1);
      if (i != _index) HapticFeedback.selectionClick();
      setState(() {
        _page = p;
        _index = i;
      });
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _join(NearbyEvent e) async {
    setState(() => _busy = true);
    unawaited(HapticFeedback.heavyImpact());
    final ok = await rejoindreEvenement(context, ref, e.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onJoined(e);
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    final current = events[_index];
    // La distance de L'INSTANT (2026-09-26) : elle bouge quand on marche.
    final d = liveDistanceTo(ref, current);
    final ici = current.withinReachAt(d);
    final path = current.posterPath;
    final teinte = path == null
        ? eventSeedColor(current.title)
        : ref.watch(eventPosterColorProvider(path)).value ??
              eventSeedColor(current.title);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Le fond prend la couleur de l'affiche montrée, en douceur.
        TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: teinte),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, c, _) => DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.35),
                radius: 1.15,
                colors: [
                  (c ?? teinte).withValues(alpha: 0.55),
                  (c ?? teinte).withValues(alpha: 0.12),
                  Colors.transparent,
                ],
                stops: const [0, 0.55, 1],
              ),
            ),
          ),
        ),
        Column(
          children: [
            const SizedBox(height: 8),
            Text(
              events.length == 1
                  ? 'Une soirée autour de toi'
                  : '${events.length} soirées autour de toi',
              style: TextStyle(color: context.palette.inkMuted, fontSize: 15),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: AnimatedBuilder(
                animation: widget.entrance,
                builder: (context, _) => PageView.builder(
                  controller: _pages,
                  physics: const BouncingScrollPhysics(),
                  itemCount: events.length,
                  itemBuilder: (context, i) {
                    // La montée : chaque carte un peu après la précédente.
                    final debut = (i * 0.12).clamp(0.0, 0.5);
                    final t = Curves.easeOutBack.transform(
                      ((widget.entrance.value - debut) / (1 - debut)).clamp(
                        0.0,
                        1.0,
                      ),
                    );
                    return Opacity(
                      opacity: t.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, (1 - t) * 320),
                        child: _Carte(event: events[i], delta: i - _page),
                      ),
                    );
                  },
                ),
              ),
            ),
            if (events.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: _Points(total: events.length, page: _page),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 18, 28, 20),
              child: GlowButton(
                label: ici ? 'Rejoindre la soirée' : 'Approche-toi · à $d m',
                icon: ici ? Icons.celebration_rounded : Icons.near_me_rounded,
                busy: _busy,
                onPressed: ici ? () => _join(current) : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Une carte : l'affiche, puis ce qu'il faut savoir — chaque couche décalée
/// selon [delta] (l'écart, en cartes, avec celle qu'on regarde).
class _Carte extends ConsumerWidget {
  const _Carte({required this.event, required this.delta});

  final NearbyEvent event;
  final double delta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = event;
    final d = delta.clamp(-1.5, 1.5);
    final loin = d.abs();
    final echelle = 1 - 0.07 * loin;
    final amis = ref.watch(friendProfilesProvider).value ?? const {};
    final visages = [
      for (final id in e.friendsPresent)
        if (amis[id] != null) amis[id]!,
    ];
    final me = ref.watch(currentUserIdProvider);
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..rotateY(-d * 0.18)
        ..scaleByDouble(echelle, echelle, 1, 1),
      child: Opacity(
        opacity: (1 - 0.35 * loin).clamp(0.0, 1.0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // L'affiche, qui traîne derrière son cadre.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final largeur = math.min(c.maxWidth, c.maxHeight * 3 / 4);
                    return Center(
                      child: SizedBox(
                        width: largeur,
                        child: Stack(
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    blurRadius: 30,
                                    offset: const Offset(0, 16),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: Transform.translate(
                                  offset: Offset(-d * _posterLag, 0),
                                  child: Transform.scale(
                                    scale: 1.14,
                                    child: EventPoster(
                                      title: e.title,
                                      posterPath: e.posterPath,
                                      radius: 0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: _Distance(event: e),
                            ),
                            if (me != null)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: IconButton(
                                  tooltip: 'Signaler cette soirée',
                                  icon: const Icon(
                                    Icons.more_horiz,
                                    color: Colors.white,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black54,
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                  onPressed: () => showReportSheet(
                                    context,
                                    ref,
                                    target: EventReportTarget(e.id),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Le titre, qui devance d'un rien.
              Transform.translate(
                offset: Offset(d * _titleLead, 0),
                child: Text(
                  e.venueName ?? e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Fredoka',
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
              // Les infos, qui arrivent en dernier.
              Transform.translate(
                offset: Offset(d * _infoLead, 0),
                child: Opacity(
                  opacity: (1 - loin * 1.4).clamp(0.0, 1.0),
                  child: _Infos(event: e, visages: visages),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Distance extends ConsumerWidget {
  const _Distance({required this.event});
  final NearbyEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = liveDistanceTo(ref, event);
    final ici = event.withinReachAt(d);
    return ClipRRect(
      borderRadius: BorderRadius.circular(40),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Colors.black.withValues(alpha: 0.35),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ici ? Icons.where_to_vote_rounded : Icons.near_me_rounded,
                size: 15,
                color: ici ? const Color(0xFF7CF2B0) : Colors.white,
              ),
              const SizedBox(width: 5),
              Text(
                ici ? 'Tu y es' : 'à $d m',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Infos extends StatelessWidget {
  const _Infos({required this.event, required this.visages});
  final NearbyEvent event;
  final List<Profile> visages;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final p = context.palette;
    final n = e.presentCount;
    final fin = e.scheduledEndAt;
    final lignes = [
      if (e.venueName != null) e.title,
      n == 0 ? 'personne encore' : '$n présent${n > 1 ? 's' : ''}',
      if (fin != null) "jusqu'à ${shortTime(fin.toLocal())}",
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Text(
          lignes,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.inkMuted, fontSize: 14),
        ),
        if (e.description != null) ...[
          const SizedBox(height: 8),
          Text(
            e.description!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.ink, fontSize: 15, height: 1.35),
          ),
        ],
        if (visages.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Amis(visages: visages),
        ],
      ],
    );
  }
}

/// Mes amis qui y sont : leurs visages, puis leurs noms.
class _Amis extends StatelessWidget {
  const _Amis({required this.visages});
  final List<Profile> visages;

  @override
  Widget build(BuildContext context) {
    final montres = visages.take(4).toList();
    final noms = visages.take(2).map((v) => v.chatName).join(', ');
    final reste = visages.length - 2;
    return Row(
      children: [
        SizedBox(
          width: 22.0 * montres.length + 10,
          height: 32,
          child: Stack(
            children: [
              for (var i = 0; i < montres.length; i++)
                Positioned(
                  left: 22.0 * i,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.palette.ground,
                    ),
                    child: Avatar(
                      stored: montres[i].avatarUrl,
                      radius: 14,
                      fallback: Text(
                        montres[i].chatName.characters.first.toUpperCase(),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            reste > 0
                ? '$noms et $reste autre${reste > 1 ? 's' : ''} y sont'
                : '$noms ${visages.length > 1 ? 'y sont' : 'y est'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ),
      ],
    );
  }
}

/// Les points sous le paquet : le plein suit le doigt, sans à-coup.
class _Points extends StatelessWidget {
  const _Points({required this.total, required this.page});
  final int total;
  final double page;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const max = 9;
    final n = math.min(total, max);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < n; i++)
          Builder(
            builder: (context) {
              final proche = (1 - (page - i).abs()).clamp(0.0, 1.0);
              return Container(
                width: 7 + 14 * proche,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: Color.lerp(p.line, p.action, proche),
                ),
              );
            },
          ),
      ],
    );
  }
}
