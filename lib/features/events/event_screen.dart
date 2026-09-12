import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/clock.dart';
import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/top_banner.dart';
import '../conversations/chat_screen.dart';
import '../library_vibes/conversation_library_screen.dart';
import 'event_invite_screen.dart';
import 'event_settings_screen.dart';
import 'events_providers.dart';
import 'events_repository.dart';
import 'events_screen.dart';

/// **Le mode événement** — « toute une autre partie » de l'app (Jay,
/// 2026-09-12), qui n'existe que le temps d'un événement.
///
/// Ce que l'écran montre, de haut en bas :
///
/// 1. **l'état** — en cours, pas commencé, terminé — et le geste qui va avec
///    (« Je suis là », « Quitter ») ;
/// 2. **les points chauds** — où sont les gens, en nombre, jamais en
///    position (le serveur ne rend que des cases agrégées) ;
/// 3. **les outils du groupe d'événement** — le chat, la bibliothèque
///    retardée, et l'emplacement des jeux et défis (question 16 du §12,
///    pas encore tranchée : la place est là, pas le contenu) ;
/// 4. **les gens** — présents d'abord, puis invités, avec leur relation.
///
/// ⚠️ **Deux façons d'arriver ici.** Par mes événements (l'objet complet est
/// dans `myEventsProvider`), ou par « autour de moi » (je n'y suis pas encore
/// : seul l'aperçu de la liste existe). Dans le second cas l'écran montre
/// l'aperçu et le bouton pour entrer — rien d'autre n'est encore à moi.
class EventScreen extends ConsumerWidget {
  const EventScreen({super.key, required this.eventId, this.preview});

  final String eventId;
  final NearbyVenueEvent? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final event = ref.watch(eventByIdProvider(eventId));
    final loading = ref.watch(myEventsProvider).isLoading;

    if (event == null) {
      if (loading && preview == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      return _Apercu(eventId: eventId, preview: preview);
    }

    final now = ref.watch(expiryClockProvider);
    final people = ref.watch(eventPeopleProvider(eventId));
    final hotSpots = ref.watch(eventHotSpotsProvider(eventId));

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          children: [
            Text(event.title),
            if (event.venueName != null)
              Text(event.venueName!, style: context.sectionMeta),
          ],
        ),
        actions: [
          if (event.canSettings(me))
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Réglages',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EventSettingsScreen(eventId: eventId),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myEventsProvider);
          ref.invalidate(eventPeopleProvider(eventId));
          ref.invalidate(eventHotSpotsProvider(eventId));
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _Etat(event: event, now: now),
            if (event.iAmPresent)
              _PointsChauds(spots: hotSpots.value ?? const []),
            if (event.iAmPresent || event.isClosed) _Outils(event: event),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      event.kind == EventKind.venue
                          ? 'Présents'
                          : 'Invités et présents',
                      style: context.sectionTitle,
                    ),
                  ),
                  if (event.canInvite(me))
                    TextButton.icon(
                      icon: const Icon(Icons.person_add_alt_1, size: 18),
                      label: const Text('Inviter'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => EventInviteScreen(eventId: eventId),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            people.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text(messageServeur(e)),
              ),
              data: (list) => Column(
                children: [
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Personne pour l\'instant.',
                        style: TextStyle(color: context.muted),
                      ),
                    ),
                  for (final person in list)
                    _Personne(event: event, person: person, me: me),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// L'état, et le geste : entrer ou sortir.
class _Etat extends ConsumerWidget {
  const _Etat({required this.event, required this.now});
  final NeoEvent event;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final me = ref.watch(currentUserIdProvider)!;
    final String titre;
    final String detail;
    if (event.isClosed) {
      titre = 'Terminé';
      final reveal = event.libraryRevealAt;
      detail = reveal == null
          ? 'Le groupe reste ouvert cinq jours.'
          : reveal.isAfter(now)
          ? 'La bibliothèque se révèle ${dayAndTime(reveal)}. Le groupe '
                'reste ouvert cinq jours.'
          : 'Bibliothèque révélée. Le groupe reste ouvert cinq jours.';
    } else if (event.notStartedAt(now)) {
      titre = 'Commence ${dayAndTime(event.startsAt)}';
      detail = event.kind == EventKind.private
          ? '${event.guestCount} invité${event.guestCount > 1 ? 's' : ''}. '
                'On rejoint sur place, une fois commencé.'
          : 'On rejoint sur place, une fois commencé.';
    } else if (event.iAmPresent) {
      titre = 'Tu es là';
      detail =
          '${event.presentCount} présent${event.presentCount > 1 ? 's' : ''}'
          '${event.scheduledEndAt == null ? '' : ' · ferme ${dayAndTime(event.scheduledEndAt!)}'}';
    } else {
      titre = 'En cours';
      detail =
          '${event.presentCount} présent${event.presentCount > 1 ? 's' : ''}. '
          '${event.hasPlace ? 'Rejoins en étant sur place.' : 'Rejoins près des participants.'}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: event.iAmPresent
              ? p.action.withValues(alpha: 0.12)
              : p.surface,
          borderRadius: BorderRadius.circular(NeoRadius.md),
          border: Border.all(color: p.line),
        ),
        padding: const EdgeInsets.all(NeoSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              titre,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(detail, style: TextStyle(color: context.muted)),
            const SizedBox(height: 12),
            Row(
              children: [
                if (event.isOpen && !event.notStartedAt(now))
                  event.iAmPresent
                      ? OutlinedButton.icon(
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('Quitter'),
                          onPressed: () async {
                            try {
                              await ref
                                  .read(eventsRepositoryProvider)
                                  .leave(event.id);
                            } catch (e) {
                              if (context.mounted) {
                                TopBanner.show(
                                  context,
                                  messageServeur(e),
                                  tone: TopBannerTone.already,
                                );
                              }
                            }
                          },
                        )
                      : FilledButton.icon(
                          icon: const Icon(Icons.place, size: 18),
                          label: const Text('Je suis là'),
                          onPressed: () =>
                              rejoindreEvenement(context, ref, event.id),
                        ),
                const Spacer(),
                if (event.canClose(me))
                  TextButton(
                    onPressed: () => _confirmerFermeture(context, ref, event),
                    child: const Text('Fermer l\'événement'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
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
          'Tout le monde en sort. Le chat et la bibliothèque restent '
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
}

/// « Comme sur Snap » : où sont les gens, en nombre. Une case = un point
/// chaud ; le lieu déclaré compte 0 et n'est pas listé.
class _PointsChauds extends StatelessWidget {
  const _PointsChauds({required this.spots});
  final List<HotSpot> spots;

  @override
  Widget build(BuildContext context) {
    final vivants = [
      for (final s in spots)
        if (s.headcount > 0) s,
    ]..sort((a, b) => b.headcount.compareTo(a.headcount));
    if (vivants.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (i, s) in vivants.indexed)
            Chip(
              avatar: Icon(
                Icons.local_fire_department,
                size: 16,
                color: i == 0 ? p.warm : p.inkMuted,
              ),
              label: Text(
                '${s.headcount} ${s.headcount > 1 ? 'personnes' : 'personne'}',
              ),
            ),
        ],
      ),
    );
  }
}

/// Les outils du groupe d'événement.
class _Outils extends StatelessWidget {
  const _Outils({required this.event});
  final NeoEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _Outil(
              icon: Icons.chat_bubble_outline,
              label: 'Chat',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ChatScreen(conversationId: event.conversationId),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Outil(
              icon: Icons.photo_library_outlined,
              label: 'Bibliothèque',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConversationLibraryScreen(
                    conversationId: event.conversationId,
                    title: event.title,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Outil(
              icon: Icons.sports_esports_outlined,
              label: 'Jeux',
              // La place est réservée ; le contenu est la question 16 du §12.
              onTap: () => TopBanner.show(
                context,
                'Les jeux et défis arrivent — ils se décident avec Jay.',
                tone: TopBannerTone.already,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Outil extends StatelessWidget {
  const _Outil({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(NeoRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NeoRadius.md),
            border: Border.all(color: p.line),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon),
              const SizedBox(height: 4),
              Text(label, style: context.tagName),
            ],
          ),
        ),
      ),
    );
  }
}

class _Personne extends ConsumerWidget {
  const _Personne({
    required this.event,
    required this.person,
    required this.me,
  });
  final NeoEvent event;
  final EventPerson person;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final relation = switch (person.relation) {
      PersonRelation.me => 'toi',
      PersonRelation.friend => 'ami·e',
      PersonRelation.event => 'de l\'événement',
      PersonRelation.none => '',
    };
    final role = person.role == null
        ? ''
        : person.role == EventRole.admin
        ? ' · admin'
        : ' · invité·e';
    final peutRetirer =
        person.userId != me &&
        person.userId != event.createdBy &&
        person.invited &&
        event.canRemove(me);
    final peutRegler =
        event.kind == EventKind.private &&
        event.createdBy == me &&
        person.userId != me &&
        person.invited &&
        event.isOpen;

    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Avatar(
            stored: person.avatarUrl,
            radius: 20,
            fallback: Text(person.chatName.characters.first.toUpperCase()),
          ),
          if (person.present)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: p.action,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.ground, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(person.chatName),
      subtitle: Text(
        '${person.present ? 'Présent·e' : 'Pas encore là'}'
        '${relation.isEmpty ? '' : ' · $relation'}$role',
      ),
      trailing: (peutRetirer || peutRegler)
          ? PopupMenuButton<String>(
              onSelected: (v) async {
                final repo = ref.read(eventsRepositoryProvider);
                try {
                  switch (v) {
                    case 'retirer':
                      await repo.remove(event.id, person.userId);
                    case 'admin':
                      await repo.setRole(
                        event.id,
                        person.userId,
                        EventRole.admin,
                      );
                    case 'membre':
                      await repo.setRole(
                        event.id,
                        person.userId,
                        EventRole.member,
                      );
                  }
                } catch (e) {
                  if (context.mounted) {
                    TopBanner.show(
                      context,
                      messageServeur(e),
                      tone: TopBannerTone.already,
                    );
                  }
                }
              },
              itemBuilder: (_) => [
                if (peutRegler && person.role != EventRole.admin)
                  const PopupMenuItem(
                    value: 'admin',
                    child: Text('Rendre admin'),
                  ),
                if (peutRegler && person.role == EventRole.admin)
                  const PopupMenuItem(
                    value: 'membre',
                    child: Text('Retirer les droits admin'),
                  ),
                if (peutRetirer)
                  const PopupMenuItem(
                    value: 'retirer',
                    child: Text('Retirer de l\'événement'),
                  ),
              ],
            )
          : null,
    );
  }
}

/// Un événement que je ne connais que par « autour de moi ».
class _Apercu extends ConsumerWidget {
  const _Apercu({required this.eventId, required this.preview});
  final String eventId;
  final NearbyVenueEvent? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = preview;
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text(v?.title ?? 'Événement')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: v == null
            ? Text(
                'Cet événement n\'est plus disponible.',
                style: TextStyle(color: context.muted),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.venueName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (v.venueAddress != null)
                    Text(
                      v.venueAddress!,
                      style: TextStyle(color: context.muted),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '${v.presentCount} présent${v.presentCount > 1 ? 's' : ''}'
                    ' · à ${v.distanceM} m'
                    '${v.scheduledEndAt == null ? '' : ' · ferme ${dayAndTime(v.scheduledEndAt!)}'}',
                    style: TextStyle(color: context.muted),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.place, size: 18),
                    label: const Text('Je suis là'),
                    onPressed: () => rejoindreEvenement(context, ref, eventId),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    v.withinReach
                        ? 'Tu es assez près pour entrer.'
                        : 'Approche-toi : on rejoint en étant sur place.',
                    style: TextStyle(color: context.muted),
                  ),
                ],
              ),
      ),
    );
  }
}
