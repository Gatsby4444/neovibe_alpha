import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/message.dart';
import '../../core/models/nearby_user.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../connections/connections_repository.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../library/user_library_screen.dart';
import 'ble_service.dart';
import 'proximity_repository.dart';

/// Croisement ping consigné côté serveur (table encounters, remplie par
/// resolve_ble_tokens) : le profil minimal d'une personne croisée reste
/// accessible après l'éloignement (consigne Jay 2026-07-12).
class Encounter {
  const Encounter({required this.peerId, required this.lastSeenAt});
  final String peerId;
  final DateTime lastSeenAt;
}

final encountersProvider = FutureProvider<List<Encounter>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('encounters')
      .select()
      .order('last_seen_at', ascending: false)
      .limit(50);
  return rows
      .map(
        (row) => Encounter(
          peerId: row['user_low'] == me
              ? row['user_high'] as String
              : row['user_low'] as String,
          lastSeenAt: DateTime.parse(row['last_seen_at'] as String),
        ),
      )
      .toList();
});

/// Module Ping (plein écran, ouvert depuis Cercle) : liste des personnes à
/// proximité BLE, conversations ping en cours, croisements récents.
/// Cliquer une personne ouvre son profil (avec Message + Ajouter).
class PingScreen extends ConsumerWidget {
  const PingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final ble = ref.watch(bleServiceProvider);
    // Instancie le repository pour démarrer le heartbeat des demandes.
    ref.watch(proximityRepositoryProvider);

    final conversations = ref.watch(conversationsProvider).value ?? [];
    final partials = ref.watch(partialConnectionsProvider);
    // Conversations ping visibles : pair en portée BLE ou lien partiel en
    // cours. Hors de portée, elles disparaissent de la liste (mais restent
    // 24 h côté serveur : elles reviennent si on se recroise).
    final pingConversations = conversations.where((c) {
      if (c.type != ConversationType.proximity || c.lastMessage == null) {
        return false;
      }
      final peer = c.otherMember(me);
      if (peer == null) return false;
      final inRange = ble.nearby.values.any((u) => u.userId == peer.id);
      final hasPartial = partials.any((p) => p.peerIdFor(me) == peer.id);
      return inRange || hasPartial;
    }).toList();

    final encounters = ref.watch(encountersProvider).value ?? [];
    final nearbyIds = ble.nearby.values.map((u) => u.userId).toSet();
    // Croisés récemment : uniquement ceux qui ne sont plus en portée
    final pastEncounters = encounters
        .where((e) => !nearbyIds.contains(e.peerId))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Ping')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(encountersProvider);
          ref.invalidate(conversationsProvider);
        },
        child: ListView(
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
            const _SectionTitle('Autour de toi'),
            if (!ble.visible)
              const _EmptyHint(
                icon: Icons.bluetooth_disabled,
                text:
                    'Ta visibilité est coupée.\nPersonne ne peut te détecter, et tu ne détectes personne.',
              )
            else if (ble.nearbyList.isEmpty)
              const _EmptyHint(
                icon: Icons.radar,
                text:
                    'Personne à proximité pour l\'instant.\nLes membres NeoVibe proches apparaîtront ici.',
              )
            else
              for (final user in ble.nearbyList) _NearbyTile(user: user),
            if (pingConversations.isNotEmpty) ...[
              const _SectionTitle('Conversations ping'),
              for (final conv in pingConversations)
                ListTile(
                  leading: const Icon(Icons.podcasts),
                  title: Text(conv.displayName(me)),
                  subtitle: Text(
                    conv.lastMessage?.body ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    shortTime(conv.lastMessage!.createdAt),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(conversationId: conv.id),
                    ),
                  ),
                ),
            ],
            if (pastEncounters.isNotEmpty) ...[
              const _SectionTitle('Croisés récemment'),
              for (final encounter in pastEncounters)
                _EncounterTile(encounter: encounter),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _NearbyTile extends ConsumerWidget {
  const _NearbyTile({required this.user});
  final NearbyUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      trailing: const Icon(Icons.chevron_right),
      // Le clic ouvre le PROFIL (les actions Message / Ajouter y vivent) —
      // consigne Jay 2026-07-12.
      onTap: () => _openProfile(context, ref, user.userId),
    );
  }
}

class _EncounterTile extends ConsumerWidget {
  const _EncounterTile({required this.encounter});
  final Encounter encounter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peer = ref.watch(profileByIdProvider(encounter.peerId)).value;
    if (peer == null) return const SizedBox.shrink();
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
      subtitle: Text('Croisé ${vagueTimeAgo(encounter.lastSeenAt)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openProfile(context, ref, encounter.peerId),
    );
  }
}

Future<void> _openProfile(
  BuildContext context,
  WidgetRef ref,
  String userId,
) async {
  final profile = await ref.read(profileByIdProvider(userId).future);
  if (profile == null || !context.mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: profile)),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Colors.white24),
          const SizedBox(height: 12),
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
