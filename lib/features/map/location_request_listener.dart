import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/notifications/notification_service.dart';
import '../../core/supabase_providers.dart';

/// **« Un ami te demande ta position » — la notification** (Jay,
/// 2026-09-26). Écoute EN DIRECT les demandes qui me visent
/// (`location_requests`, dans la publication temps réel ; la table ne laisse
/// voir que les siennes) et affiche une notification sur le téléphone. La
/// demande elle-même, avec Accepter / Refuser, est dans le chat.
///
/// ⚠️ **La limite, dite** : ceci vit dans l'app. App ouverte ou en
/// arrière-plan, la notification arrive ; app TUÉE par Android, rien —
/// il faudrait des notifications à distance (Firebase), qui n'existent pas
/// encore. La demande attend alors dans le chat (15 min pour répondre).
class LocationRequestListener {
  LocationRequestListener(this.ref) {
    _subscribe();
    ref.onDispose(() => _channel?.unsubscribe());
  }

  final Ref ref;
  RealtimeChannel? _channel;

  void _subscribe() {
    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser?.id;
    if (me == null) return;
    _channel = client.channel('location-requests:$me')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'location_requests',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'target_id',
          value: me,
        ),
        callback: (payload) => _onDemande(payload.newRecord),
      )
      ..subscribe();
  }

  Future<void> _onDemande(Map<String, dynamic> record) async {
    try {
      final qui = await ref
          .read(supabaseProvider)
          .from('profiles')
          .select('display_name')
          .eq('id', record['requester_id'] as String)
          .single();
      await NotificationService.instance.show(
        NotifChannel.position,
        '${qui['display_name']} te demande ta position',
        'Ouvre votre conversation pour accepter ou refuser.',
      );
    } catch (_) {
      // Notification au mieux : ne jamais faire échouer l'app pour ça.
    }
  }
}

final locationRequestListenerProvider = Provider<LocationRequestListener>((
  ref,
) {
  // Recrée l'abonnement à chaque changement d'utilisateur connecté.
  ref.watch(currentUserIdProvider);
  return LocationRequestListener(ref);
});
