import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/nearby_user.dart';
import '../../core/utils/formats.dart';
import '../connections/connections_repository.dart';
import '../library/user_library_screen.dart';
import '../stories/stories_bar.dart';
import '../stories/stories_repository.dart';
import 'ping_chat_screen.dart';
import 'ping_store.dart';
import 'proximity_service.dart';

/// Module Ping (plein écran, ouvert depuis Cercle) — 100 % BLE LOCAL
/// (chantier A, décisions Jay 2026-07-13) : personnes à proximité
/// (amis reconnus par ID rotatif, inconnus révélés par poignée de main
/// chiffrée), conversations ping locales (TTL 12 h, jamais serveur),
/// croisements récents certifiés.
class PingScreen extends ConsumerStatefulWidget {
  const PingScreen({super.key});

  @override
  ConsumerState<PingScreen> createState() => _PingScreenState();
}

class _PingScreenState extends ConsumerState<PingScreen> {
  List<PingConversation> _conversations = const [];
  List<LocalEncounter> _encounters = const [];

  /// Capturé à l'initialisation : `ref` est INTERDIT dans `dispose()` (le
  /// widget est déjà démonté — Riverpod lève « Using "ref" when a widget is
  /// about to or has been unmounted », vu dans le journal de Jay).
  late final _store = ref.read(pingStoreProvider);

  @override
  void initState() {
    super.initState();
    _store.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _store.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    // `_store` capturé, JAMAIS `ref.read` ici : `_reload` est appelé par un
    // écouteur du store (mise à jour BLE), qui peut tomber pendant que l'écran
    // est en train d'être démonté → Riverpod lève « Using "ref" when a widget
    // is about to or has been unmounted » (4 occurrences dans le journal de Jay
    // du 2026-07-25). Le champ `_store` avait été introduit pour ça, mais cette
    // ligne était restée en arrière.
    final convs = await _store.conversations();
    final encounters = await _store.encounters();
    if (!mounted) return;
    setState(() {
      _conversations = convs;
      _encounters = encounters;
    });
  }

  @override
  Widget build(BuildContext context) {
    final proximity = ref.watch(proximityServiceProvider);
    final nearby = proximity.nearbyList;
    final nearbyIds = proximity.nearby.keys.toSet();

    // Conversations ping visibles : pair en portée. Hors de portée, elles
    // sortent de la liste (mais restent 12 h en local : elles reviennent si
    // on se recroise).
    final visibleConversations = _conversations
        .where((c) => nearbyIds.contains(c.peerId))
        .toList();

    // Croisés récemment : plus en portée, profil + certificat en local.
    final pastEncounters = _encounters
        .where((e) => !nearbyIds.contains(e.peer.userId))
        .toList();

    final pendingRequest = proximity.incomingFriendRequest;

    return Scaffold(
      appBar: AppBar(title: const Text('Ping')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          children: [
            // Stories des personnes croisées (consigne Jay 2026-08-02) :
            // uniquement celles qui ont activé « stories publiques », et
            // uniquement si le croisement certifié date de moins de 24 h.
            StoriesBar(
              provider: crossedStoriesProvider,
              emptyHint:
                  'Pas de story des gens que tu croises. Elles n\'apparaissent '
                  'que si la personne a activé ses stories publiques.',
            ),
            SwitchListTile(
              title: const Text('Visible à proximité'),
              subtitle: Text(
                proximity.visible
                    ? 'Les autres membres NeoVibe proches peuvent te voir'
                    : 'Active pour rencontrer ceux qui te croisent',
              ),
              value: proximity.visible,
              onChanged: (on) => on
                  ? ref.read(proximityServiceProvider.notifier).enable()
                  : ref.read(proximityServiceProvider.notifier).disable(),
            ),
            if (proximity.visible)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Découverte 100 % locale : ton identifiant change toutes '
                  'les 15 minutes et ton profil ne circule que dans un canal '
                  'chiffré, d\'appareil à appareil.',
                  style: TextStyle(color: context.faint, fontSize: 11),
                ),
              ),
            if (proximity.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  proximity.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (pendingRequest != null)
              _FriendRequestBanner(request: pendingRequest),
            const _SectionTitle('Autour de toi'),
            if (!proximity.visible)
              const _EmptyHint(
                icon: Icons.bluetooth_disabled,
                text:
                    'Ta visibilité est coupée.\nPersonne ne peut te détecter, et tu ne détectes personne.',
              )
            else if (nearby.isEmpty)
              const _EmptyHint(
                icon: Icons.radar,
                text:
                    'Personne à proximité pour l\'instant.\nLes membres NeoVibe proches apparaîtront ici.',
              )
            else
              for (final peer in nearby) _NearbyTile(peer: peer),
            if (visibleConversations.isNotEmpty) ...[
              const _SectionTitle('Conversations ping'),
              for (final conv in visibleConversations)
                ListTile(
                  leading: const Icon(Icons.podcasts),
                  title: Text(conv.peer.displayName),
                  subtitle: Text(
                    conv.messages.isEmpty ? '' : conv.messages.last.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: conv.messages.isEmpty
                      ? null
                      : Text(
                          shortTime(conv.messages.last.at),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          PingChatScreen(peerId: conv.peerId, peer: conv.peer),
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

/// Demande d'ami reçue en BLE (co-signée) : accepter échange les clés de
/// reconnaissance et remontera au serveur au retour d'internet.
class _FriendRequestBanner extends ConsumerWidget {
  const _FriendRequestBanner({required this.request});
  final PendingBleFriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(proximityServiceProvider.notifier);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${request.snapshot.displayName} veut se connecter avec toi',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Vous êtes à proximité en ce moment',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () =>
                      service.respondToFriendRequest(accept: false),
                  child: const Text('Refuser'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => service.respondToFriendRequest(accept: true),
                  child: const Text('Accepter'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NearbyTile extends ConsumerWidget {
  const _NearbyTile({required this.peer});
  final NearbyPeer peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = peer.snapshot;
    return ListTile(
      leading: CircleAvatar(
        child: Text(snapshot.displayName.characters.first.toUpperCase()),
      ),
      title: Text(snapshot.displayName),
      subtitle: Row(
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: peer.proximity == ProximityLevel.veryClose
                ? Colors.greenAccent
                : Colors.amber,
          ),
          const SizedBox(width: 6),
          Text(peer.proximity.label),
          if (peer.isFriend) ...[
            const SizedBox(width: 10),
            const Icon(Icons.link, size: 14),
            const SizedBox(width: 4),
            const Text('Déjà connectés'),
          ],
        ],
      ),
      // Message direct (100 % BLE, marche sans internet) + profil complet
      // (serveur, si internet) au tap — consigne Jay 2026-07-12 conservée.
      trailing: IconButton(
        icon: const Icon(Icons.chat_bubble_outline),
        tooltip: 'Message ping',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                PingChatScreen(peerId: snapshot.userId, peer: snapshot),
          ),
        ),
      ),
      onTap: () => _openProfile(context, ref, snapshot),
    );
  }
}

class _EncounterTile extends ConsumerWidget {
  const _EncounterTile({required this.encounter});
  final LocalEncounter encounter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: CircleAvatar(
        child: Text(encounter.peer.displayName.characters.first.toUpperCase()),
      ),
      title: Text(encounter.peer.displayName),
      subtitle: Text('Croisé ${vagueTimeAgo(encounter.at)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openProfile(context, ref, encounter.peer),
    );
  }
}

/// Ouvre le profil complet (serveur). Sans internet, retombe sur la
/// conversation ping locale.
Future<void> _openProfile(
  BuildContext context,
  WidgetRef ref,
  PingPeerSnapshot snapshot,
) async {
  try {
    final profile = await ref.read(profileByIdProvider(snapshot.userId).future);
    if (profile != null && context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: profile)),
      );
      return;
    }
  } catch (_) {
    // Hors ligne : pas de profil serveur.
  }
  if (context.mounted) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PingChatScreen(peerId: snapshot.userId, peer: snapshot),
      ),
    );
  }
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
          Icon(icon, size: 48, color: context.ghost),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.muted),
          ),
        ],
      ),
    );
  }
}
