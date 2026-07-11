import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/nearby_user.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import 'ble_service.dart';
import 'proximity_repository.dart';

/// Écran Ping : visibilité BLE + liste temps réel des utilisateurs proches
/// (spec 4.2 / 4.3).
class NearbyScreen extends ConsumerWidget {
  const NearbyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble = ref.watch(bleServiceProvider);
    final incoming = ref.watch(incomingRequestsProvider).value ?? [];
    // Instancie le repository pour démarrer le heartbeat des demandes.
    ref.watch(proximityRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('À proximité')),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Visible à proximité'),
            subtitle: Text(
              ble.visible
                  ? 'Les autres membres NeoVibe proches peuvent te voir'
                  : 'Active pour rencontrer ceux qui te croisent',
            ),
            value: ble.visible,
            onChanged: (on) => on
                ? ref.read(bleServiceProvider.notifier).enable()
                : ref.read(bleServiceProvider.notifier).disable(),
          ),
          if (ble.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                ble.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final request in incoming)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.waving_hand),
                title: Text(
                  '${request.sender?.displayName ?? 'Quelqu\'un'} veut se connecter',
                ),
                subtitle: const Text('Vous êtes à proximité en ce moment'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () => ref
                          .read(proximityRepositoryProvider)
                          .accept(request.id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => ref
                          .read(proximityRepositoryProvider)
                          .decline(request.id),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: !ble.visible
                ? const _EmptyHint(
                    icon: Icons.bluetooth_disabled,
                    text:
                        'Ta visibilité est coupée.\nPersonne ne peut te détecter, et tu ne détectes personne.',
                  )
                : ble.nearbyList.isEmpty
                ? const _EmptyHint(
                    icon: Icons.radar,
                    text:
                        'Personne à proximité pour l\'instant.\nLes membres NeoVibe proches apparaîtront ici.',
                  )
                : ListView(
                    children: [
                      for (final user in ble.nearbyList)
                        _NearbyTile(user: user),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _NearbyTile extends ConsumerWidget {
  const _NearbyTile({required this.user});
  final NearbyUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outgoing = ref.watch(outgoingRequestsProvider).value ?? [];
    final alreadyRequested = outgoing.any((r) => r.receiverId == user.userId);

    return ListTile(
      leading: CircleAvatar(
        backgroundImage: user.avatarUrl == null
            ? null
            : NetworkImage(user.avatarUrl!),
        child: user.avatarUrl == null
            ? Text(user.displayName.characters.first.toUpperCase())
            : null,
      ),
      title: Text(user.displayName),
      subtitle: Row(
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: user.proximity == ProximityLevel.veryClose
                ? Colors.greenAccent
                : Colors.amber,
          ),
          const SizedBox(width: 6),
          Text(user.proximity.label),
          if (user.isConnected) ...[
            const SizedBox(width: 10),
            const Icon(Icons.link, size: 14),
            const SizedBox(width: 4),
            const Text('Déjà connectés'),
          ],
        ],
      ),
      trailing: user.isConnected
          ? IconButton(
              icon: const Icon(Icons.chat_bubble_outline),
              tooltip: 'Message',
              onPressed: () async {
                final convId = await ref
                    .read(conversationsRepositoryProvider)
                    .getOrCreateDirect(user.userId);
                if (context.mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(conversationId: convId),
                    ),
                  );
                }
              },
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Messagerie de proximité : premier contact léger (spec 4.4)
                IconButton(
                  icon: const Icon(Icons.chat_bubble_outline),
                  tooltip: 'Message de proximité',
                  onPressed: () async {
                    final convId = await ref
                        .read(conversationsRepositoryProvider)
                        .getOrCreateProximity(user.userId);
                    if (context.mounted) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(conversationId: convId),
                        ),
                      );
                    }
                  },
                ),
                alreadyRequested
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Envoyé'),
                      )
                    : FilledButton.tonal(
                        onPressed: () async {
                          try {
                            await ref
                                .read(proximityRepositoryProvider)
                                .sendRequest(user.userId);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Erreur : $e')),
                              );
                            }
                          }
                        },
                        child: const Text('Se connecter'),
                      ),
              ],
            ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.white24),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}
