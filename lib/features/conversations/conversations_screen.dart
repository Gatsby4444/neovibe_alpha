import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/message.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../cards/cards_repository.dart';
import 'chat_screen.dart';
import 'conversations_repository.dart';
import 'create_group_screen.dart';

class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final conversations = ref.watch(conversationsProvider);
    // Hot boost : les livraisons Hot ouvertes vite remontent en tête (privé)
    final hotBoosts = (ref.watch(receivedDeliveriesProvider).value ?? [])
        .where((d) => d.hotBoosted)
        .map((d) => d.cardId)
        .toSet();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversations'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Nouveau groupe',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(conversationsProvider),
        child: conversations.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Erreur : $e'),
              ),
            ],
          ),
          data: (list) {
            // Les conversations proximité sans message visible n'apparaissent pas
            final visible = list
                .where(
                  (c) =>
                      c.type != ConversationType.proximity ||
                      c.lastMessage != null,
                )
                .toList();
            if (visible.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 120),
                  Icon(Icons.forum_outlined, size: 56, color: Colors.white24),
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Aucune conversation.\nConnecte-toi à quelqu\'un que tu croises pour commencer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ],
              );
            }
            return ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final conv = visible[index];
                final last = conv.lastMessage;
                final boosted =
                    last?.cardId != null && hotBoosts.contains(last!.cardId);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage:
                        conv.otherMember(me)?.avatarUrl != null &&
                            conv.type == ConversationType.direct
                        ? NetworkImage(conv.otherMember(me)!.avatarUrl!)
                        : null,
                    child: conv.type == ConversationType.group
                        ? const Icon(Icons.group)
                        : (conv.otherMember(me)?.avatarUrl == null
                              ? Text(
                                  conv
                                      .displayName(me)
                                      .characters
                                      .first
                                      .toUpperCase(),
                                )
                              : null),
                  ),
                  title: Row(
                    children: [
                      Expanded(child: Text(conv.displayName(me))),
                      if (boosted)
                        const Icon(
                          Icons.local_fire_department,
                          color: Color(0xFFFF7A1A),
                          size: 18,
                        ),
                    ],
                  ),
                  subtitle: Text(
                    switch (last?.kind) {
                      null => 'Nouvelle conversation',
                      MessageKind.text => last!.body ?? '',
                      MessageKind.image => '📷 Photo',
                      MessageKind.video => '🎥 Vidéo',
                      MessageKind.card => '🃏 Card',
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: last == null
                      ? null
                      : Text(
                          shortTime(last.createdAt),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                  onTap: () => Navigator.of(context)
                      .push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(conversationId: conv.id),
                        ),
                      )
                      .then((_) => ref.invalidate(conversationsProvider)),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
