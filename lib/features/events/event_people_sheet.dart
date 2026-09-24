import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/top_banner.dart';
import 'event_invite_screen.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **Les participants d'une soirée** — la feuille qui s'ouvre en touchant le
/// cadre des présents de l'écran de soirée (Jay, 2026-09-24 : *« un container
/// qui deviendra cliquable pour afficher la liste des participants »*).
///
/// Elle reprend TELLE QUELLE la liste de l'ancien écran d'événement :
/// présents d'abord, leur relation (toi, ami·e, de l'événement), leur rôle, et
/// les gestes de l'organisateur (rendre admin, retirer). Rien n'a été perdu en
/// changeant d'écran — seul le rangement a bougé.
Future<void> showEventPeople(BuildContext context, String eventId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, controller) =>
            _PeopleList(eventId: eventId, controller: controller),
      ),
    );

class _PeopleList extends ConsumerWidget {
  const _PeopleList({required this.eventId, required this.controller});

  final String eventId;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final event = ref.watch(eventByIdProvider(eventId));
    final people = ref.watch(eventPeopleProvider(eventId));
    if (event == null) return const SizedBox.shrink();

    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: NeoSpace.xxl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  event.kind == EventKind.venue
                      ? 'Les présents'
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
                EventPersonTile(event: event, person: person, me: me),
            ],
          ),
        ),
      ],
    );
  }
}

/// Une personne de la soirée, avec les gestes que j'ai le droit d'avoir sur
/// elle. Déplacée de `event_screen.dart` le 2026-09-24, inchangée.
class EventPersonTile extends ConsumerWidget {
  const EventPersonTile({
    super.key,
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
