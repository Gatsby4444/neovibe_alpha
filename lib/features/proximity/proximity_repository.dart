import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection_request.dart';
import '../../core/supabase_providers.dart';
import 'ble_service.dart';

/// Demandes de connexion reçues, en attente et non expirées (temps réel).
final incomingRequestsProvider = StreamProvider<List<ConnectionRequest>>((ref) {
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
    final ble = ref.read(bleServiceProvider.notifier);
    final outgoing = ref.read(outgoingRequestsProvider).value ?? [];
    final client = ref.read(supabaseProvider);
    for (final request in outgoing) {
      if (ble.isInRange(request.receiverId)) {
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

  Future<void> sendRequest(String receiverId) async {
    final me = ref.read(supabaseProvider).auth.currentUser!.id;
    await ref.read(supabaseProvider).from('connection_requests').insert({
      'sender_id': me,
      'receiver_id': receiverId,
    });
  }

  Future<void> accept(String requestId) => ref
      .read(supabaseProvider)
      .rpc('accept_connection_request', params: {'req_id': requestId});

  Future<void> decline(String requestId) => ref
      .read(supabaseProvider)
      .rpc('decline_connection_request', params: {'req_id': requestId});
}

final proximityRepositoryProvider = Provider((ref) => ProximityRepository(ref));
