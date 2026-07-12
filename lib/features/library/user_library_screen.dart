import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../proximity/ble_service.dart';
import '../proximity/proximity_repository.dart';
import 'library_repository.dart';
import 'profile_header.dart';
import 'profile_screen.dart';

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
    final ble = ref.watch(bleServiceProvider);
    final inRange = ble.nearby.values.any((u) => u.userId == profile.id);
    final outgoing = ref.watch(outgoingRequestsProvider).value ?? [];
    final alreadyRequested = outgoing.any((r) => r.receiverId == profile.id);

    return Scaffold(
      appBar: AppBar(title: Text(profile.displayName)),
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
                  // Inconnu en portée BLE : conversation ping (3 messages max
                  // sans réponse) + demande de connexion, sans lien entre les
                  // deux (pas de connexion automatique — consigne Jay).
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.podcasts),
                      label: const Text('Message'),
                      onPressed: () => _openProximity(context, ref),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: alreadyRequested
                        ? const OutlinedButton(
                            onPressed: null,
                            child: Text('Demande envoyée'),
                          )
                        : FilledButton.icon(
                            icon: const Icon(Icons.person_add_alt),
                            label: const Text('Ajouter'),
                            onPressed: () async {
                              try {
                                await ref
                                    .read(proximityRepositoryProvider)
                                    .sendRequest(profile.id);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Erreur : $e')),
                                  );
                                }
                              }
                            },
                          ),
                  ),
                ] else
                  const Expanded(
                    child: Text(
                      'Hors de portée — recroisez-vous pour échanger.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'Bibliothèque',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Rien à voir ici — bibliothèque vide ou accès restreint.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                    itemCount: list.length,
                    itemBuilder: (context, index) =>
                        LibraryTile(item: list[index]),
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

  Future<void> _openProximity(BuildContext context, WidgetRef ref) async {
    final convId = await ref
        .read(conversationsRepositoryProvider)
        .getOrCreateProximity(profile.id);
    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(conversationId: convId)),
      );
    }
  }
}
