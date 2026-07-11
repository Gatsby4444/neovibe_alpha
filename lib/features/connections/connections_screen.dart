import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../library/user_library_screen.dart';
import '../recommendations/recommendations_repository.dart';
import '../recommendations/recommendation_screens.dart';
import 'connections_repository.dart';

/// Mon cercle : connexions complètes, liens partiels à confirmer,
/// et le hub des recommandations A→B→C.
class ConnectionsScreen extends ConsumerWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final full = ref.watch(fullConnectionsProvider);
    final partial = ref.watch(partialConnectionsProvider);
    final inbox = ref.watch(recommendationInboxProvider).value ?? [];
    final proposals = ref.watch(recommendationProposalsProvider).value ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('Mon cercle')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(recommendationInboxProvider);
          ref.invalidate(recommendationProposalsProvider);
          ref.invalidate(myRecommendationRequestsProvider);
        },
        child: ListView(
          children: [
            // Propositions reçues (je suis C)
            if (proposals.isNotEmpty) ...[
              const _SectionTitle('Propositions de mise en relation'),
              for (final reco in proposals)
                Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.handshake),
                    title: Text(
                      '${reco.intermediary?.displayName ?? 'Un ami'} te propose ${reco.requester?.displayName ?? 'quelqu\'un'}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check, color: Colors.green),
                          onPressed: () async {
                            await ref
                                .read(recommendationsRepositoryProvider)
                                .accept(reco.id);
                            ref.invalidate(recommendationProposalsProvider);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () async {
                            await ref
                                .read(recommendationsRepositoryProvider)
                                .decline(reco.id);
                            ref.invalidate(recommendationProposalsProvider);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            // Demandes à transmettre (je suis A)
            if (inbox.isNotEmpty) ...[
              const _SectionTitle('Demandes à transmettre'),
              for (final reco in inbox)
                Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.forward),
                    title: Text(
                      '${reco.requester?.displayName ?? '?'} cherche : "${reco.targetHint}"',
                    ),
                    subtitle: const Text(
                      'Choisis à qui transmettre, ou ignore',
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ForwardRecommendationScreen(recommendation: reco),
                      ),
                    ),
                  ),
                ),
            ],
            // Liens partiels (3 jours pour confirmer)
            if (partial.isNotEmpty) ...[
              const _SectionTitle('Liens partiels — à confirmer'),
              for (final connection in partial)
                _PartialTile(connection: connection, me: me),
            ],
            const _SectionTitle('Connexions'),
            if (full.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Personne pour l\'instant. Tes connexions naissent dans la vraie vie : '
                  'active ta visibilité quand tu sors, ou demande une mise en relation à un ami.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            for (final connection in full)
              _ConnectionTile(connection: connection, me: me),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.connect_without_contact),
                label: const Text('Demander une mise en relation'),
                onPressed: full.isEmpty
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RequestRecommendationScreen(),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _PartialTile extends ConsumerWidget {
  const _PartialTile({required this.connection, required this.me});
  final Connection connection;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peer = ref.watch(profileByIdProvider(connection.peerIdFor(me))).value;
    final confirmed = connection.confirmedBy(me);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.hourglass_bottom, color: Colors.amber),
        title: Text(peer?.displayName ?? '…'),
        subtitle: Text(
          'Expire dans ${remaining(connection.partialExpiresAt!)}'
          '${confirmed ? ' · tu as confirmé ✓' : ''}',
        ),
        trailing: confirmed
            ? null
            : FilledButton.tonal(
                onPressed: () => ref
                    .read(connectionsRepositoryProvider)
                    .confirmPartial(connection.id),
                child: const Text('Confirmer'),
              ),
      ),
    );
  }
}

class _ConnectionTile extends ConsumerWidget {
  const _ConnectionTile({required this.connection, required this.me});
  final Connection connection;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peerId = connection.peerIdFor(me);
    final peer = ref.watch(profileByIdProvider(peerId)).value;
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: peer?.avatarUrl == null
            ? null
            : NetworkImage(peer!.avatarUrl!),
        child: peer?.avatarUrl == null
            ? Text((peer?.displayName ?? '?').characters.first.toUpperCase())
            : null,
      ),
      title: Text(peer?.displayName ?? '…'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Bibliothèque',
            onPressed: peer == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => UserLibraryScreen(profile: peer),
                    ),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Message',
            onPressed: () async {
              final convId = await ref
                  .read(conversationsRepositoryProvider)
                  .getOrCreateDirect(peerId);
              if (context.mounted) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(conversationId: convId),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
