import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../library/user_library_screen.dart';
import 'connections_repository.dart';

/// Liste des amis (consigne Jay 2026-07-12) : ouverte depuis le compteur
/// d'amis du profil — username + PP + barre de recherche.
class FriendsListScreen extends ConsumerStatefulWidget {
  const FriendsListScreen({super.key});

  @override
  ConsumerState<FriendsListScreen> createState() => _FriendsListScreenState();
}

class _FriendsListScreenState extends ConsumerState<FriendsListScreen> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mes amis')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: const InputDecoration(
                hintText: 'Rechercher un ami…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: connections.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Personne pour l\'instant. Tes connexions naissent '
                        'dans la vraie vie : active ta visibilité quand tu sors.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final connection in connections)
                        _FriendTile(
                          peerId: connection.peerIdFor(me),
                          query: _query,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _FriendTile extends ConsumerWidget {
  const _FriendTile({required this.peerId, required this.query});
  final String peerId;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Profile? peer = ref.watch(profileByIdProvider(peerId)).value;
    if (peer == null) return const SizedBox.shrink();
    if (query.isNotEmpty &&
        !peer.displayName.toLowerCase().contains(query) &&
        !(peer.tagName?.toLowerCase().contains(query) ?? false)) {
      return const SizedBox.shrink();
    }
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: peer.avatarUrl == null
            ? null
            : NetworkImage(peer.avatarUrl!),
        child: peer.avatarUrl == null
            ? Text(peer.displayName.characters.first.toUpperCase())
            : null,
      ),
      title: Text(peer.displayName),
      subtitle: peer.tagName == null || peer.tagName!.isEmpty
          ? null
          : Text(peer.tagName!),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: peer)),
      ),
    );
  }
}
