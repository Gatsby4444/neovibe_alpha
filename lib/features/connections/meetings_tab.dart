import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/models/profile.dart';
import '../../core/theme.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../events/events_providers.dart';
import '../events/events_repository.dart';
import '../library/open_profile.dart';

/// **Personnes rencontrées** — la mémoire des rencontres (Jay, 2026-09-21),
/// présentée comme ChatGPT le conseillait : *« NeoVibe t'aide à retrouver
/// les personnes que tu as rencontrées »*, jamais *« croisé 17 fois »*.
///
/// Chaque ligne : qui, **où** (« Rencontré(e) à Soirée X », « Croisé(e) »),
/// quand. Un appui ouvre le profil restreint (publications et stories
/// publiques) ; glisser efface la rencontre de MA mémoire — l'autre garde la
/// sienne. Deux ans, puis le serveur oublie seul.
class MeetingsTab extends ConsumerWidget {
  const MeetingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meetings = ref.watch(myMeetingsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(myMeetingsProvider);
        await ref.read(myMeetingsProvider.future);
      },
      child: meetings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(messageServeur(e))),
        data: (list) => list.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 100),
                  Icon(Icons.people_outline, size: 56, color: context.ghost),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Personne pour l\'instant.\nLes gens que tu rencontres '
                      'dans une soirée, ou que tu croises assez longtemps, '
                      'sont gardés ici — où et quand — pendant deux ans.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  ),
                ],
              )
            : ListView(
                children: [for (final m in list) _MeetingTile(meeting: m)],
              ),
      ),
    );
  }
}

class _MeetingTile extends ConsumerWidget {
  const _MeetingTile({required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = meeting;
    final fois = m.times > 1 ? ' · ${m.times} fois' : '';
    return Dismissible(
      key: ValueKey(m.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Oublier cette rencontre ?'),
          content: Text(
            '${m.displayName} disparaît de ta mémoire. La sienne ne change pas.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Garder'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Oublier'),
            ),
          ],
        ),
      ),
      onDismissed: (_) =>
          ref.read(eventsRepositoryProvider).forgetMeeting(m.id),
      child: ListTile(
        leading: Avatar(
          stored: m.avatarUrl,
          fallback: Text(
            m.displayName.isEmpty
                ? '?'
                : m.displayName.characters.first.toUpperCase(),
          ),
        ),
        title: Text(m.displayName),
        subtitle: Text('${m.where} · ${dayAndTime(m.metAt)}$fois'),
        trailing: m.connected
            ? Icon(Icons.favorite, size: 18, color: context.palette.action)
            : null,
        onTap: () => openProfile(
          context,
          Profile(
            id: m.userId,
            displayName: m.displayName,
            tagName: m.tagName,
            // `my_meetings` rend déjà le pseudo MONTRÉ (`pseudo_shown`).
            pseudoShown: m.tagName,
            avatarUrl: m.avatarUrl,
          ),
        ),
      ),
    );
  }
}
