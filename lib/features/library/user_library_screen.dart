import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../connections/connections_repository.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../proximity/ping_chat_screen.dart';
import '../proximity/ping_store.dart';
import '../proximity/proximity_service.dart';
import 'library_deck_screen.dart';
import 'library_repository.dart';
import 'mini_card.dart';
import 'profile_header.dart';

/// Profil d'un autre utilisateur — connexion OU personne croisée en ping.
/// En-tête commun (PP, username, stats, bio) + bibliothèque : la RLS ne
/// laisse passer que ce que j'ai le droit de voir (tout pour une connexion
/// selon ses règles, uniquement les contenus PUBLICS pour un simple croisé).
/// Actions (consigne Jay 2026-07-12) : Message + Ajouter côte à côte.
class UserLibraryScreen extends ConsumerWidget {
  const UserLibraryScreen({super.key, required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final items = ref.watch(libraryItemsProvider(profile.id));
    final connections = ref.watch(fullConnectionsProvider);
    final isConnected = connections.any((c) => c.peerIdFor(me) == profile.id);
    final proximity = ref.watch(proximityServiceProvider);
    final inRange = proximity.nearby.containsKey(profile.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(profile.displayName),
        // Signaler / bloquer une PERSONNE. Sans ce point d'entrée, le
        // signalement de profil était inatteignable (v0.9.53 → 2026-08-12) : le
        // menu n'existait que sur les stories et les publications. C'est aussi
        // le seul recours pour une Vibe reçue en DM, qui n'a pas de Content ID.
        actions: [
          if (profile.id != me)
            ContentOverflowMenu(
              authorId: profile.id,
              authorName: profile.displayName,
              color:
                  Theme.of(context).appBarTheme.foregroundColor ??
                  Theme.of(context).colorScheme.onSurface,
            ),
        ],
      ),
      body: ListView(
        children: [
          ProfileHeader(profile: profile),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                if (isConnected)
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message'),
                      onPressed: () => _openDirect(context, ref),
                    ),
                  )
                else if (inRange) ...[
                  // Inconnu en portée BLE : conversation ping LOCALE (100 %
                  // BLE, 3 messages max sans réponse) + demande de connexion
                  // co-signée d'appareil à appareil (chantier BLE
                  // 2026-07-13) — sans lien entre les deux (pas de connexion
                  // automatique, consigne Jay).
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.podcasts),
                      label: const Text('Message'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PingChatScreen(
                            peerId: profile.id,
                            peer: PingPeerSnapshot(
                              userId: profile.id,
                              username: profile.displayName,
                              tagName: profile.tagName,
                              verified: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Ajouter'),
                      onPressed: () async {
                        try {
                          await ref
                              .read(proximityServiceProvider.notifier)
                              .sendFriendRequest(profile.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Demande envoyée directement à son appareil.',
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  e.toString().replaceFirst('Bad state: ', ''),
                                ),
                              ),
                            );
                          }
                        }
                      },
                    ),
                  ),
                ] else
                  Expanded(
                    child: Text(
                      'Hors de portée — recroisez-vous pour échanger.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Bibliothèque',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.view_carousel_outlined),
                  tooltip: 'Parcourir en deck',
                  onPressed: () {
                    final list = items.value;
                    if (list == null || list.isEmpty) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LibraryDeckScreen(
                          items: list,
                          title: profile.displayName,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          items.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Erreur : $e'),
            ),
            data: (list) => list.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Rien à voir ici — bibliothèque vide ou accès restreint.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  )
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(10),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: kMiniCardRatio,
                        ),
                    itemCount: list.length,
                    itemBuilder: (context, index) =>
                        MiniCard(item: list[index]),
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _openDirect(BuildContext context, WidgetRef ref) async {
    final convId = await ref
        .read(conversationsRepositoryProvider)
        .getOrCreateDirect(profile.id);
    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(conversationId: convId)),
      );
    }
  }
}
