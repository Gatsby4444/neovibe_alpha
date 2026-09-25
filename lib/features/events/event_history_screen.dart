import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/saved_store.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../cards/saved_items_screen.dart';
import '../connections/connections_repository.dart';
import '../gallery/moment_store.dart';
import '../library_vibes/conversation_library_screen.dart';
import 'events_providers.dart';

/// **L'historique de mes événements** — les soirées où j'ai été, en albums :
/// où, quand, avec qui, ce qu'on y a fait (le récap).
///
/// Déménagé de la galerie le 2026-09-25 (Jay : *« le but de la galerie n'est
/// pas d'afficher à nouveau la porte d'entrée vers le récap de l'événement
/// mais uniquement les Vibes datées et localisées »* ; le récap *« dans un
/// historique d'événements accessible via un nouveau bouton dans l'interface
/// Événements »*, et pas dans Pulse).
///
/// Tout vient du téléphone ([momentsProvider]) : les albums survivent à la
/// purge des événements côté serveur.
class EventHistoryScreen extends ConsumerWidget {
  const EventHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moments = ref.watch(momentsProvider);
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Historique')),
      body: moments.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (list) => list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Rien encore.\nChaque soirée où tu vas trouvera sa '
                    'place ici : où, quand, avec qui, et ce que vous y avez '
                    'fait.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) => _AlbumTile(moment: list[i]),
              ),
      ),
    );
  }
}

class _AlbumTile extends ConsumerWidget {
  const _AlbumTile({required this.moment});
  final Moment moment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final m = moment;
    final friends = ref.watch(friendProfilesProvider).value ?? const {};
    final noms = [
      for (final id in m.friends.take(3))
        if (friends[id] != null) friends[id]!.chatName,
    ];
    final avecQui = m.friends.isEmpty
        ? null
        : 'Avec ${noms.join(', ')}'
              '${m.friends.length > noms.length ? ' et ${m.friends.length - noms.length} autre${m.friends.length - noms.length > 1 ? 's' : ''}' : ''}';
    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(NeoRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.md),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => MomentScreen(momentId: m.id))),
        child: Container(
          padding: const EdgeInsets.all(NeoSpace.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NeoRadius.md),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: p.field,
                child: Icon(
                  m.autoCreated
                      ? Icons.auto_awesome
                      : m.kind == 'venue'
                      ? Icons.storefront
                      : m.kind == 'open'
                      ? Icons.celebration
                      : Icons.group,
                  color: p.ink,
                ),
              ),
              const SizedBox(width: NeoSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${dayAndTime(m.startedAt)}'
                      '${m.venueName != null ? ' · ${m.venueName}' : ''}',
                      style: TextStyle(color: context.muted, fontSize: 12),
                    ),
                    if (avecQui != null)
                      Text(
                        avecQui,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: context.muted, fontSize: 12),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${m.vibeCount} Vibe${m.vibeCount > 1 ? 's' : ''}',
                    style: context.sectionMeta,
                  ),
                  if (m.isOpen)
                    Text(
                      'En cours',
                      style: TextStyle(color: p.action, fontSize: 12),
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

/// **Un moment** : où, quand, avec qui, ce qu'on y a fait, et ce qu'il en
/// reste — le Drop tant qu'il vit, les Vibes gardées pour toujours.
class MomentScreen extends ConsumerWidget {
  const MomentScreen({super.key, required this.momentId});
  final String momentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moment = (ref.watch(momentsProvider).value ?? const [])
        .where((m) => m.id == momentId)
        .firstOrNull;
    if (moment == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Text(
            'Ce moment n\'est plus là.',
            style: TextStyle(color: context.muted),
          ),
        ),
      );
    }
    final m = moment;
    final p = context.palette;
    final friends = ref.watch(friendProfilesProvider).value ?? const {};
    final live = ref.watch(eventByIdProvider(m.id));
    final rencontres = (ref.watch(myMeetingsProvider).value ?? const [])
        .where((r) => r.eventId == m.id)
        .toList();
    final saved = (ref.watch(savedItemsProvider).value ?? const [])
        .where((s) => m.keptVibeIds.contains(s.contentId))
        .toList();

    Widget chiffre(int n, String mot, String pluriel) => Expanded(
      child: Column(
        children: [
          Text(
            '$n',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            n > 1 ? pluriel : mot,
            style: TextStyle(color: context.muted, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text(m.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            '${dayAndTime(m.startedAt)}'
            '${m.closedAt != null ? ' → ${shortTime(m.closedAt!)}' : ' · en cours'}'
            '${m.venueName != null ? '\n${m.venueName}' : ''}',
            style: TextStyle(color: context.muted),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(NeoRadius.md),
              border: Border.all(color: p.line),
            ),
            padding: const EdgeInsets.all(NeoSpace.lg),
            child: Row(
              children: [
                chiffre(m.presentCount, 'présent', 'présents'),
                chiffre(m.vibeCount, 'Vibe', 'Vibes'),
                chiffre(m.metCount, 'rencontré', 'rencontrés'),
                chiffre(m.newFriendCount, 'nouvel ami', 'nouveaux amis'),
              ],
            ),
          ),
          if (live != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: Text(
                m.isOpen ? 'Ouvrir le Drop' : 'Le Drop, encore quelques jours',
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConversationLibraryScreen(
                    conversationId: live.conversationId,
                    title: live.title,
                  ),
                ),
              ),
            ),
          ],
          if (m.friends.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Avec', style: context.sectionTitle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (final id in m.friends)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(
                        stored: friends[id]?.avatarUrl,
                        radius: 22,
                        fallback: Text(
                          (friends[id]?.chatName ?? '?').characters.first
                              .toUpperCase(),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        friends[id]?.chatName ?? '…',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
              ],
            ),
          ],
          if (rencontres.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Rencontrés là', style: context.sectionTitle),
            for (final r in rencontres)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Avatar(
                  stored: r.avatarUrl,
                  fallback: Text(
                    r.displayName.isEmpty
                        ? '?'
                        : r.displayName.characters.first.toUpperCase(),
                  ),
                ),
                title: Text(r.displayName),
                subtitle: Text(
                  r.connected ? 'Ami depuis' : 'Rencontré(e) ici',
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
              ),
          ],
          const SizedBox(height: 20),
          Text('Vibes gardées', style: context.sectionTitle),
          const SizedBox(height: 8),
          if (saved.isEmpty)
            Text(
              m.kept
                  ? 'Aucune Vibe gardée : celles du Drop étaient éphémères.'
                  : 'Les Vibes du Drop (sauf les éphémères) seront gardées '
                        'dans ta galerie à la fin de l\'événement.',
              style: TextStyle(color: context.muted),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 9 / 16,
              ),
              itemCount: saved.length,
              itemBuilder: (context, i) => SavedTile(item: saved[i]),
            ),
        ],
      ),
    );
  }
}
