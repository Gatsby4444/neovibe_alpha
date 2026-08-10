import 'package:flutter/material.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection_request.dart';
import '../../core/models/recommendation.dart';
import '../../core/models/wave.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../proximity/proximity_repository.dart';
import '../recommendations/recommendation_screens.dart';
import '../recommendations/recommendations_repository.dart';
import 'connections_repository.dart';

/// Historique des Waves : uniquement les croisements dont l'heure de
/// notification est passée (le différé reste différé), horodatage flou,
/// jamais de position (spec 4.11).
final wavesProvider = FutureProvider<List<Wave>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('waves')
      .select()
      .eq('user_id', me)
      .lte('notify_after', DateTime.now().toUtc().toIso8601String())
      .order('detected_at', ascending: false)
      .limit(50);
  return rows.map(Wave.fromJson).toList();
});

/// Historique de MES demandes de connexion (reçues + envoyées, tous statuts).
final requestHistoryProvider = FutureProvider<List<ConnectionRequest>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('connection_requests')
      .select()
      .order('created_at', ascending: false)
      .limit(50);
  return rows.map(ConnectionRequest.fromJson).toList();
});

/// Section « cœur » du Profil (consigne Jay 2026-07-12) : historique des
/// demandes de connexion, des recommandations A→B→C et des Waves.
class HeartScreen extends ConsumerWidget {
  const HeartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Demandes & rencontres'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Demandes'),
              Tab(text: 'Recos'),
              Tab(text: 'Waves'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_RequestsTab(), _RecommendationsTab(), _WavesTab()],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Demandes de connexion
// ---------------------------------------------------------------------------

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final incoming = ref.watch(incomingRequestsProvider).value ?? [];
    final partial = ref.watch(partialConnectionsProvider);
    final history = ref.watch(requestHistoryProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(requestHistoryProvider),
      child: ListView(
        children: [
          if (incoming.isNotEmpty) ...[
            const _SectionTitle('En attente — vous êtes à proximité'),
            for (final request in incoming)
              _IncomingRequestTile(request: request),
          ],
          if (partial.isNotEmpty) ...[
            const _SectionTitle('Liens partiels — à confirmer'),
            for (final connection in partial)
              _PartialTile(connectionId: connection.id, me: me),
          ],
          const _SectionTitle('Historique'),
          history.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Erreur : $e'),
            ),
            data: (list) => list.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Aucune demande pour l\'instant.\nElles naissent dans la vraie vie, en croisant quelqu\'un.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  )
                : Column(
                    children: [
                      for (final request in list)
                        _HistoryTile(request: request, me: me),
                    ],
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _IncomingRequestTile extends ConsumerWidget {
  const _IncomingRequestTile({required this.request});
  final ConnectionRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sender = ref.watch(profileByIdProvider(request.senderId)).value;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Avatar(
          stored: sender?.avatarUrl,
          fallback: Text(
            (sender?.displayName ?? '?').characters.first.toUpperCase(),
          ),
        ),
        title: Text('${sender?.displayName ?? 'Quelqu\'un'} veut se connecter'),
        subtitle: const Text('Vous êtes à proximité en ce moment'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.check, color: Colors.green),
              onPressed: () =>
                  ref.read(proximityRepositoryProvider).accept(request.id),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () =>
                  ref.read(proximityRepositoryProvider).decline(request.id),
            ),
          ],
        ),
      ),
    );
  }
}

class _PartialTile extends ConsumerWidget {
  const _PartialTile({required this.connectionId, required this.me});
  final String connectionId;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref
        .watch(partialConnectionsProvider)
        .where((c) => c.id == connectionId)
        .firstOrNull;
    if (connection == null) return const SizedBox.shrink();
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

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.request, required this.me});
  final ConnectionRequest request;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sent = request.senderId == me;
    final peerId = sent ? request.receiverId : request.senderId;
    final peer = ref.watch(profileByIdProvider(peerId)).value;
    final label = switch (request.status) {
      RequestStatus.pending =>
        request.isActive ? 'en attente' : 'expirée (hors de portée)',
      RequestStatus.accepted => 'acceptée ✓',
      RequestStatus.declined => 'refusée',
      RequestStatus.expired => 'expirée (hors de portée)',
    };
    return ListTile(
      dense: true,
      leading: Icon(
        sent ? Icons.call_made : Icons.call_received,
        size: 18,
        color: request.status == RequestStatus.accepted
            ? Colors.green
            : context.faint,
      ),
      title: Text(peer?.displayName ?? '…'),
      subtitle: Text('${sent ? 'Envoyée' : 'Reçue'} · $label'),
    );
  }
}

// ---------------------------------------------------------------------------
// Recommandations A→B→C
// ---------------------------------------------------------------------------

class _RecommendationsTab extends ConsumerWidget {
  const _RecommendationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(recommendationInboxProvider).value ?? [];
    final proposals = ref.watch(recommendationProposalsProvider).value ?? [];
    final mine = ref.watch(myRecommendationRequestsProvider).value ?? [];
    final hasConnections = ref.watch(fullConnectionsProvider).isNotEmpty;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(recommendationInboxProvider);
        ref.invalidate(recommendationProposalsProvider);
        ref.invalidate(myRecommendationRequestsProvider);
      },
      child: ListView(
        children: [
          if (proposals.isNotEmpty) ...[
            const _SectionTitle('Propositions de mise en relation'),
            for (final reco in proposals)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.handshake),
                  title: Text(
                    '${reco.intermediary?.displayName ?? 'Un ami'} te propose '
                    '${reco.requester?.displayName ?? 'quelqu\'un'}',
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
          if (inbox.isNotEmpty) ...[
            const _SectionTitle('Demandes à transmettre'),
            for (final reco in inbox)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.forward),
                  title: Text(
                    '${reco.requester?.displayName ?? '?'} cherche : "${reco.targetHint}"',
                  ),
                  subtitle: const Text('Choisis à qui transmettre, ou ignore'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ForwardRecommendationScreen(recommendation: reco),
                    ),
                  ),
                ),
              ),
          ],
          const _SectionTitle('Mes demandes'),
          if (mine.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Aucune demande de mise en relation en cours.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted),
              ),
            ),
          for (final reco in mine)
            ListTile(
              dense: true,
              leading: const Icon(Icons.connect_without_contact, size: 18),
              title: Text('« ${reco.targetHint} »'),
              subtitle: Text(
                'via ${reco.intermediary?.displayName ?? '?'} · '
                '${switch (reco.status) {
                  RecommendationStatus.accepted => 'acceptée ✓',
                  _ => 'en attente',
                }}',
              ),
            ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.connect_without_contact),
              label: const Text('Demander une mise en relation'),
              onPressed: !hasConnections
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
    );
  }
}

// ---------------------------------------------------------------------------
// Waves — « le presque »
// ---------------------------------------------------------------------------

class _WavesTab extends ConsumerWidget {
  const _WavesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waves = ref.watch(wavesProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(wavesProvider),
      child: waves.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (list) => list.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 100),
                  Icon(Icons.waving_hand, size: 56, color: context.ghost),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Aucun croisement manqué.\nQuand une de tes connexions passera près de toi, tu le sauras… après coup.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  ),
                ],
              )
            : ListView(
                children: [for (final wave in list) _WaveTile(wave: wave)],
              ),
      ),
    );
  }
}

class _WaveTile extends ConsumerWidget {
  const _WaveTile({required this.wave});
  final Wave wave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peer = ref.watch(profileByIdProvider(wave.peerId)).value;
    return ListTile(
      leading: Avatar(
        stored: peer?.avatarUrl,
        fallback: Text(
          (peer?.displayName ?? '?').characters.first.toUpperCase(),
        ),
      ),
      title: Text('${peer?.displayName ?? 'Quelqu\'un'} est passé tout près'),
      subtitle: Text(vagueTimeAgo(wave.detectedAt)),
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
