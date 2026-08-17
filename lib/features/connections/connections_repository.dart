import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';

/// Profil par id, mis en cache (résolu selon les droits RLS).
final profileByIdProvider = FutureProvider.family<Profile?, String>((
  ref,
  id,
) async {
  final data = await ref
      .watch(supabaseProvider)
      .from('profiles')
      .select()
      .eq('id', id)
      .maybeSingle();
  return data == null ? null : Profile.fromJson(data);
});

/// Mes connexions (partielles et complètes), temps réel.
final connectionsStreamProvider = StreamProvider<List<Connection>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('connections')
      .stream(primaryKey: ['id'])
      .map(
        (rows) =>
            rows.map(Connection.fromJson).toList()
              ..sort((a, b) => a.status.index.compareTo(b.status.index)),
      );
});

final fullConnectionsProvider = Provider<List<Connection>>((ref) {
  final all = ref.watch(connectionsStreamProvider).value ?? [];
  return all.where((c) => c.status == ConnectionStatus.full).toList();
});

final partialConnectionsProvider = Provider<List<Connection>>((ref) {
  final all = ref.watch(connectionsStreamProvider).value ?? [];
  return all
      .where(
        (c) =>
            c.status == ConnectionStatus.partial &&
            (c.partialExpiresAt?.isAfter(DateTime.now()) ?? false),
      )
      .toList();
});

class ConnectionsRepository {
  ConnectionsRepository(this.ref);
  final Ref ref;

  Future<void> confirmPartial(String connectionId) => ref
      .read(supabaseProvider)
      .rpc('confirm_partial_connection', params: {'conn_id': connectionId});

  Future<void> remove(String connectionId) => ref
      .read(supabaseProvider)
      .from('connections')
      .delete()
      .eq('id', connectionId);
}

final connectionsRepositoryProvider = Provider(
  (ref) => ConnectionsRepository(ref),
);
