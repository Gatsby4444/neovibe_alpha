import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection_request.dart';
import '../../core/supabase_providers.dart';
import 'presence_feed.dart';

/// Demandes de connexion SERVEUR : depuis le chantier BLE (2026-07-13), les
/// demandes de proximité passent d'appareil à appareil (co-signées, cf.
/// ProximityService.sendFriendRequest). Ce canal serveur ne sert plus qu'aux
/// recommandations A→B→C et à l'historique de la section cœur.

/// Demandes de connexion reçues, en attente et non expirées (temps réel).
final incomingRequestsProvider = StreamProvider<List<ConnectionRequest>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('connection_requests')
      .stream(primaryKey: ['id'])
      .eq('receiver_id', me)
      .map(
        (rows) => rows
            .map(ConnectionRequest.fromJson)
            .where((r) => r.isActive)
            .toList(),
      );
});

/// Mes demandes sortantes en attente (pour l'état des boutons + heartbeat).
final outgoingRequestsProvider = StreamProvider<List<ConnectionRequest>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('connection_requests')
      .stream(primaryKey: ['id'])
      .eq('sender_id', me)
      .map(
        (rows) => rows
            .map(ConnectionRequest.fromJson)
            .where((r) => r.isActive)
            .toList(),
      );
});

class ProximityRepository {
  ProximityRepository(this.ref) {
    // Heartbeat : tant que le destinataire d'une demande sortante reste en
    // portée BLE, on prolonge expires_at. Sortie de portée → la demande
    // expire d'elle-même (spec 4.2 : pas de connexion en attente indéfinie).
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    ref.onDispose(() => _heartbeat.cancel());
  }

  final Ref ref;
  late final Timer _heartbeat;

  Future<void> _refresh() async {
    final nearby = ref.read(nearbyUserIdsProvider);
    final outgoing = ref.read(outgoingRequestsProvider).value ?? [];
    final client = ref.read(supabaseProvider);
    for (final request in outgoing) {
      final inRange = nearby.contains(request.receiverId);
      if (inRange) {
        await client
            .from('connection_requests')
            .update({
              'expires_at': DateTime.now()
                  .add(const Duration(seconds: 90))
                  .toUtc()
                  .toIso8601String(),
            })
            .eq('id', request.id);
      }
    }
  }

  // ⚠️ `sendRequest` a été supprimée le 2026-08-16 : plus aucun appelant.
  // Une demande de proximité part désormais d'appareil à appareil, co-signée
  // (`ProximityController.requestFriendship`), et les recommandations A→B→C ont
  // leur propre dépôt. Ce fichier ne garde donc que la RÉPONSE à une demande
  // serveur et l'historique — la seule chose qui passe encore par ce canal.

  Future<void> accept(String requestId) => ref
      .read(supabaseProvider)
      .rpc('accept_connection_request', params: {'req_id': requestId});

  Future<void> decline(String requestId) => ref
      .read(supabaseProvider)
      .rpc('decline_connection_request', params: {'req_id': requestId});
}

final proximityRepositoryProvider = Provider((ref) => ProximityRepository(ref));
