import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/clock.dart';
import '../../core/models/event.dart';
import '../../core/models/library_vibe.dart';
import '../../core/motion.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/ambience.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/stage.dart';
import '../../core/widgets/top_banner.dart';
import '../cards/card_capture_screen.dart';
import '../conversations/chat_screen.dart';
import '../library_vibes/conversation_library_screen.dart';
import '../library_vibes/library_target.dart';
import '../library_vibes/library_vibes_repository.dart';
import 'event_challenges_screen.dart';
import 'event_finder_screen.dart';
import 'event_invite_screen.dart';
import 'event_people_sheet.dart';
import 'event_settings_screen.dart';
import 'events_map_screen.dart';
import 'events_providers.dart';
import 'events_repository.dart';
import 'events_screen.dart';

/// **L'écran de soirée** — le mode événement, redessiné le 2026-09-24 sur
/// l'écran « Tu es dedans » de l'arrivée en soirée, validé par Jay : *« on voit
/// directement les vibes créées dans l'événement, avec le titre et quand elles
/// ont été publiées […] en haut les participants […] un bouton pour ajouter une
/// vibe directement dans l'affichage du drop et encore un autre en bas de
/// l'écran, superposé, les défis en bas »*.
///
/// Toujours sur la **scène de nuit** ([NightStage]), quel que soit le thème.
///
/// ## Ce que l'ancien écran faisait, et où c'est maintenant
///
/// | Ancien écran | Ici |
/// |---|---|
/// | l'état + « Je suis là » / « Quitter » / « Fermer » | l'en-tête ; « Je suis là » en bas ; Quitter et Fermer dans « ⋯ » |
/// | les points chauds + la carte | des pastilles sous l'en-tête ; la carte en haut |
/// | Chat, Drop, Défis (trois tuiles) | chat en haut ; le Drop EST l'écran ; les défis en bas |
/// | la liste des gens, rôles, « Inviter » | le cadre des présents ouvre la liste ([showEventPeople]) |
/// | réglages | dans « ⋯ » |
/// | le récap du lendemain | sous l'en-tête, une fois fermé |
/// | l'aperçu d'une soirée pas encore rejointe | [VenueFoundView], le même que le radar |
class EventScreen extends ConsumerWidget {
  const EventScreen({super.key, required this.eventId, this.preview});

  final String eventId;
  final NearbyEvent? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final event = ref.watch(eventByIdProvider(eventId));
    final loading = ref.watch(myEventsProvider).isLoading;

    final Widget body;
    if (event == null) {
      if (loading && preview == null) {
        body = const Center(child: CircularProgressIndicator());
      } else if (preview == null) {
        body = Center(
          child: Text(
            'Cette soirée n\'est plus disponible.',
            style: TextStyle(color: context.muted),
          ),
        );
      } else {
        // Pas encore dedans : le « Tu es au … » du radar. Une fois entré,
        // `myEventsProvider` se relit et cet écran devient la soirée.
        body = VenueFoundView(event: preview!);
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
                Expanded(child: body),
              ],
            ),
          ),
        ),
      );
    }

    return NightStage(
      // Plus vif quand on est dedans — comme « Tu es dedans » dans le test.
      intensity: event.iAmPresent ? NeoAmbience.soiree : 1,
      child: _Party(event: event),
    );
  }
}

class _Party extends ConsumerStatefulWidget {
  const _Party({required this.event});

  final NeoEvent event;

  @override
  ConsumerState<_Party> createState() => _PartyState();
}

class _PartyState extends ConsumerState<_Party>
    with SingleTickerProviderStateMixin {
  static const _parts = 5;

  late final _enter = AnimationController(
    vsync: this,
    duration: NeoBuildIn.durationFor(_parts) * 2,
  )..forward();

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Widget _in(int i, Widget child) =>
      NeoBuildIn(animation: _enter, index: i, total: _parts, child: child);

  NeoEvent get event => widget.event;

  void _addVibe({EventChallenge? challenge}) {
    Navigator.of(context).push(
      NeoFadeRoute(
        builder: (_) => CardCaptureScreen(
          libraryTarget: LibraryTarget(
            conversationId: event.conversationId,
            label: event.title,
            isGroup: true,
            isEvent: true,
            challengeId: challenge?.id,
            challengeText: challenge?.text,
          ),
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(myEventsProvider);
    ref.invalidate(eventPeopleProvider(event.id));
    ref.invalidate(eventHotSpotsProvider(event.id));
    ref.invalidate(eventChallengesProvider(event.id));
    ref.invalidate(conversationLibraryProvider(event.conversationId));
    await ref.read(conversationLibraryProvider(event.conversationId).future);
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(expiryClockProvider);
    final canAdd = event.isOpen && event.iAmPresent;
    final canJoin =
        event.isOpen && !event.iAmPresent && !event.notStartedAt(now);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _TopBar(event: event),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        NeoSpace.xl,
                        NeoSpace.xs,
                        NeoSpace.xl,
                        120,
                      ),
                      children: [
                        _in(0, _Header(event: event, now: now)),
                        if (event.isClosed) _Recap(eventId: event.id),
                        const SizedBox(height: NeoSpace.xl),
                        _in(1, _PresentsBox(event: event)),
                        const SizedBox(height: NeoSpace.xxl),
                        _in(
                          2,
                          _SectionTitle(
                            'Le Drop de la soirée',
                            event.isClosed
                                ? 'Ce que les présents ont vécu. Il reste '
                                      'cinq jours.'
                                : 'Ce que les présents vivent ce soir.',
                          ),
                        ),
                        const SizedBox(height: NeoSpace.md),
                        _in(
                          3,
                          _DropGrid(
                            event: event,
                            onAdd: canAdd ? _addVibe : null,
                          ),
                        ),
                        const SizedBox(height: NeoSpace.xxl),
                        _in(
                          4,
                          _Challenges(
                            event: event,
                            onAnswer: canAdd
                                ? (c) => _addVibe(challenge: c)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (canAdd || canJoin)
              Positioned(
                left: NeoSpace.xl,
                right: NeoSpace.xl,
                bottom: NeoSpace.xl,
                child: canAdd
                    ? GlowButton(
                        label: 'Ajoute ta Vibe au Drop',
                        icon: Icons.photo_camera_rounded,
                        onPressed: _addVibe,
                      )
                    : GlowButton(
                        label: 'Je suis là',
                        icon: Icons.place_rounded,
                        onPressed: () =>
                            rejoindreEvenement(context, ref, event.id),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Retour, chat, carte, et le menu « ⋯ » (réglages, inviter, quitter,
/// fermer) — tout ce que l'ancien écran avait, rangé en haut.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.event});

  final NeoEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final canLeave = event.isOpen && event.iAmPresent;
    final canClose = event.canClose(me) && event.isOpen;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          _RoundAction(
            icon: Icons.chat_bubble_outline_rounded,
            tooltip: 'Le chat de la soirée',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    ChatScreen(conversationId: event.conversationId),
              ),
            ),
          ),
          if (event.iAmPresent)
            _RoundAction(
              icon: Icons.map_outlined,
              tooltip: 'Où sont les gens',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EventsMapScreen(eventId: event.id),
                ),
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) async {
              switch (v) {
                case 'reglages':
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EventSettingsScreen(eventId: event.id),
                    ),
                  );
                case 'inviter':
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EventInviteScreen(eventId: event.id),
                    ),
                  );
                case 'quitter':
                  await _leave(context, ref);
                case 'fermer':
                  await _confirmerFermeture(context, ref, event);
              }
            },
            itemBuilder: (_) => [
              if (event.canSettings(me))
                const PopupMenuItem(value: 'reglages', child: Text('Réglages')),
              if (event.canInvite(me))
                const PopupMenuItem(value: 'inviter', child: Text('Inviter')),
              if (canLeave)
                const PopupMenuItem(
                  value: 'quitter',
                  child: Text('Quitter la soirée'),
                ),
              if (canClose)
                const PopupMenuItem(
                  value: 'fermer',
                  child: Text('Fermer l\'événement'),
                ),
            ],
          ),
          const SizedBox(width: NeoSpace.xs),
        ],
      ),
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(eventsRepositoryProvider).leave(event.id);
    } catch (e) {
      if (context.mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    }
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: p.surface.withValues(alpha: 0.7),
          shape: CircleBorder(side: BorderSide(color: p.line)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, size: 20, color: p.ink),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _confirmerFermeture(
  BuildContext context,
  WidgetRef ref,
  NeoEvent event,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Fermer l\'événement ?'),
      content: const Text(
        'Tout le monde en sort. Le chat et le Drop restent '
        'ouverts cinq jours, puis disparaissent.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(eventsRepositoryProvider).close(event.id);
    if (context.mounted) TopBanner.show(context, 'Événement fermé.');
  } catch (e) {
    if (context.mounted) {
      TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
    }
  }
}

/// « Tu es dedans. » — ou ce qui en tient lieu selon l'état de la soirée.
class _Header extends ConsumerWidget {
  const _Header({required this.event, required this.now});

  final NeoEvent event;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final String title;
    final String? detail;
    if (event.isClosed) {
      title = 'C\'est fini.';
      detail = 'Le Drop et le chat restent ouverts cinq jours.';
    } else if (event.notStartedAt(now)) {
      title = 'Bientôt.';
      detail = 'Commence ${dayAndTime(event.startsAt)} — on rejoint sur place.';
    } else if (event.iAmPresent) {
      title = 'Tu es dedans.';
      detail = event.scheduledEndAt == null
          ? null
          : 'Ferme ${dayAndTime(event.scheduledEndAt!)}';
    } else {
      title = 'En cours.';
      detail = event.hasPlace
          ? 'Rejoins en étant sur place.'
          : 'Rejoins près des participants.';
    }
    final place = [
      if (event.venueName != null) event.venueName!,
      event.title,
    ].join(' · ');
    final spots = event.iAmPresent
        ? ref.watch(eventHotSpotsProvider(event.id)).value ?? const []
        : const <HotSpot>[];
    final hot = [
      for (final s in spots)
        if (s.headcount > 0) s,
    ]..sort((a, b) => b.headcount.compareTo(a.headcount));

    return Column(
      children: [
        StageTitle(title, gradient: true),
        const SizedBox(height: NeoSpace.xs),
        Text(
          place,
          textAlign: TextAlign.center,
          style: TextStyle(color: p.inkMuted, fontSize: 15),
        ),
        if (detail != null) ...[
          const SizedBox(height: 2),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.inkMuted, fontSize: 13),
          ),
        ],
        // « Comme sur Snap » : où sont les gens, en nombre — jamais en
        // position (le serveur ne rend que des cases agrégées).
        if (hot.isNotEmpty) ...[
          const SizedBox(height: NeoSpace.md),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: NeoSpace.sm,
            runSpacing: NeoSpace.sm,
            children: [
              for (final (i, s) in hot.take(4).indexed)
                Chip(
                  avatar: Icon(
                    Icons.local_fire_department_rounded,
                    size: 16,
                    color: i == 0 ? p.warm : p.inkMuted,
                  ),
                  label: Text(
                    '${s.headcount} ${s.headcount > 1 ? 'personnes' : 'personne'}',
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// **Le récap du lendemain** (Jay, 2026-09-21) : ce qu'on y a vécu, en
/// nombres — présents, Vibes, gens rencontrés, nouveaux amis.
class _Recap extends ConsumerWidget {
  const _Recap({required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recap = ref.watch(eventRecapProvider(eventId)).value;
    if (recap == null) return const SizedBox.shrink();
    final p = context.palette;
    Widget chiffre(int n, String mot, String pluriel) => Expanded(
      child: Column(
        children: [
          Text(
            '$n',
            style: TextStyle(
              fontFamily: NeoType.display,
              fontWeight: FontWeight.w600,
              fontSize: 22,
              color: p.ink,
            ),
          ),
          Text(
            n > 1 ? pluriel : mot,
            style: TextStyle(color: p.inkMuted, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: NeoSpace.lg),
      child: Container(
        decoration: BoxDecoration(
          color: p.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(NeoRadius.lg),
          border: Border.all(color: p.line),
        ),
        padding: const EdgeInsets.all(NeoSpace.lg),
        child: Row(
          children: [
            chiffre(recap.presentCount, 'présent', 'présents'),
            chiffre(recap.vibeCount, 'Vibe', 'Vibes'),
            chiffre(recap.metCount, 'rencontré', 'rencontrés'),
            chiffre(recap.newFriendCount, 'nouvel ami', 'nouveaux amis'),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: NeoType.display,
            fontWeight: FontWeight.w600,
            fontSize: 22,
            color: p.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: p.inkMuted, fontSize: 13.5)),
      ],
    );
  }
}

/// Les présents : moi d'abord, cerclé, puis une rangée qui se chevauche.
/// **Touché, il ouvre la liste des participants.**
class _PresentsBox extends ConsumerWidget {
  const _PresentsBox({required this.event});

  final NeoEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final me = ref.watch(currentUserIdProvider);
    final people =
        ref.watch(eventPeopleProvider(event.id)).value ?? const <EventPerson>[];
    // Les présents d'abord, puis les invités pas encore là ; moi à part.
    final others = [
      for (final x in people)
        if (x.userId != me) x,
    ]..sort((a, b) => (b.present ? 1 : 0).compareTo(a.present ? 1 : 0));
    const size = 46.0;
    final faces = others.take(6).toList();
    final present = event.presentCount;
    final String line;
    final String sub;
    if (event.iAmPresent) {
      line = 'Toi + ${(present - 1).clamp(0, 99999)}';
      sub = 'présents ce soir';
    } else {
      line = '$present présent${present > 1 ? 's' : ''}';
      sub = event.kind == EventKind.private
          ? '${event.guestCount} invité${event.guestCount > 1 ? 's' : ''}'
          : 'ce soir';
    }

    return Material(
      color: p.surface.withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(NeoRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.lg),
        onTap: () => showEventPeople(context, event.id),
        child: Container(
          padding: const EdgeInsets.all(NeoSpace.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NeoRadius.lg),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              SizedBox(
                width: size + faces.length * (size * 0.55),
                height: size,
                child: Stack(
                  children: [
                    for (var i = faces.length - 1; i >= 0; i--)
                      Positioned(
                        left: size * 0.55 * (i + 1),
                        child: _Face(person: faces[i], size: size),
                      ),
                    const MyStageHalo(size: size, breathing: false),
                  ],
                ),
              ),
              const SizedBox(width: NeoSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line,
                      style: TextStyle(
                        fontFamily: NeoType.display,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                        color: p.ink,
                      ),
                    ),
                    Text(
                      sub,
                      style: TextStyle(color: p.inkMuted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: p.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({required this.person, required this.size});

  final EventPerson person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: p.surface, width: 2.5),
      ),
      child: Opacity(
        // Un invité pas encore là se voit, mais en retrait.
        opacity: person.present ? 1 : 0.45,
        child: Avatar(
          stored: person.avatarUrl,
          radius: size / 2 - 2.5,
          fallback: Text(person.chatName.characters.first.toUpperCase()),
        ),
      ),
    );
  }
}

/// **Le Drop** : ma place d'abord (quand je peux ajouter), puis les Vibes des
/// autres — avec leur titre, leur auteur et leur heure.
class _DropGrid extends ConsumerWidget {
  const _DropGrid({required this.event, required this.onAdd});

  final NeoEvent event;

  /// Nul = je ne peux pas ajouter (pas sur place, ou soirée fermée).
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final vibes = ref.watch(conversationLibraryProvider(event.conversationId));
    final people =
        ref.watch(eventPeopleProvider(event.id)).value ?? const <EventPerson>[];
    final names = {for (final x in people) x.userId: x.chatName};
    final me = ref.watch(currentUserIdProvider);

    final list = vibes.value ?? const <LibraryVibe>[];
    // Le plus récent d'abord : c'est ce qui vient de se passer.
    final ordered = [...list]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (vibes.isLoading && list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (ordered.isEmpty && onAdd == null) {
      return Text(
        vibes.hasError
            ? 'Le Drop ne se charge pas. Tire vers le bas pour réessayer.'
            : 'Rien pour l\'instant.',
        style: TextStyle(color: p.inkMuted),
      );
    }

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: NeoSpace.sm,
      crossAxisSpacing: NeoSpace.sm,
      childAspectRatio: 9 / 16,
      children: [
        if (onAdd != null) _AddTile(onTap: onAdd!, first: ordered.isEmpty),
        for (final v in ordered)
          LibraryVibeTile(
            vibe: v,
            onRefresh: () => ref.invalidate(
              conversationLibraryProvider(event.conversationId),
            ),
            caption: _Caption(
              vibe: v,
              author: v.authorId == me ? 'Toi' : (names[v.authorId] ?? '—'),
            ),
          ),
      ],
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap, required this.first});

  final VoidCallback onTap;

  /// Le Drop est vide : la case invite à ouvrir le bal.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NeoRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          border: Border.all(color: p.action, width: 1.6),
          color: p.action.withValues(alpha: 0.08),
        ),
        padding: const EdgeInsets.all(NeoSpace.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, color: p.action, size: 34),
            const SizedBox(height: NeoSpace.xs),
            Text(
              first ? 'La première\nVibe ?' : 'Ta Vibe\nici',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: NeoType.display,
                fontWeight: FontWeight.w600,
                color: p.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le titre, l'auteur, l'heure — posés sur la tuile. L'heure suit l'horloge
/// de l'app : « il y a 2 min » devient « il y a 3 min » sans rien toucher.
class _Caption extends ConsumerWidget {
  const _Caption({required this.vibe, required this.author});

  final LibraryVibe vibe;
  final String author;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(expiryClockProvider);
    // Les légendes se posent sur une photo : blanc, comme le cadenas des
    // tuiles (la scène est toujours sombre, mais la photo, elle, peut être
    // claire — d'où le voile de `LibraryVibeTile`).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (vibe.challengeId != null)
          const Padding(
            padding: EdgeInsets.only(bottom: 2),
            child: Icon(Icons.bolt_rounded, size: 14, color: Colors.white),
          ),
        if (vibe.title != null)
          Text(
            vibe.title!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(height: 2),
        Text(
          '$author · ${timeAgo(vibe.createdAt, now: now)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}

/// Les défis : à relever sur place, à prouver par une Vibe.
class _Challenges extends ConsumerWidget {
  const _Challenges({required this.event, required this.onAnswer});

  final NeoEvent event;

  /// Nul = je ne peux pas répondre (pas sur place, ou soirée fermée).
  final ValueChanged<EventChallenge>? onAnswer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final challenges =
        ref.watch(eventChallengesProvider(event.id)).value ??
        const <EventChallenge>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          'Les défis',
          'À relever sur place, à prouver par une Vibe.',
        ),
        const SizedBox(height: NeoSpace.md),
        Wrap(
          spacing: NeoSpace.sm,
          runSpacing: NeoSpace.sm,
          children: [
            for (final c in challenges.take(6))
              ActionChip(
                avatar: Icon(Icons.bolt_rounded, color: p.warm),
                label: Text(c.text),
                onPressed: onAnswer == null ? null : () => onAnswer!(c),
              ),
            // L'écran des défis garde le reste : tous les défis, et en
            // lancer un nouveau.
            ActionChip(
              avatar: Icon(
                challenges.isEmpty ? Icons.add_rounded : Icons.flag_outlined,
                color: p.ink,
              ),
              label: Text(
                challenges.isEmpty ? 'Lancer un défi' : 'Tous les défis',
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EventChallengesScreen(eventId: event.id),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
