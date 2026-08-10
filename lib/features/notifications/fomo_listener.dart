import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/card.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/supabase_providers.dart';

/// Écouteur FOMO global (spec 4.9) — sobre : uniquement
/// « [Ami] t'a envoyé une Card [Type] » et « [Ami] a publié ».
/// (« est en train d'écrire » est un indicateur in-app, dans la conversation.)
class FomoListener {
  FomoListener(this.ref) {
    _subscribe();
    ref.onDispose(_unsubscribe);
  }

  final Ref ref;
  RealtimeChannel? _channel;

  void _subscribe() {
    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser?.id;
    if (me == null) return;

    _channel = client.channel('fomo:$me')
      // Card reçue — avec le type dans la notification (même tag que la Card)
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'card_deliveries',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: me,
        ),
        callback: (payload) => _onCardDelivered(payload.newRecord),
      )
      // Publication d'un ami dans sa bibliothèque (visible pour moi via RLS)
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'library_items',
        callback: (payload) => _onLibraryPublished(payload.newRecord),
      )
      ..subscribe();
  }

  Future<void> _onCardDelivered(Map<String, dynamic> record) async {
    final client = ref.read(supabaseProvider);
    try {
      final card = await client
          .from('cards')
          .select('card_type, owner_id')
          .eq('id', record['card_id'] as String)
          .single();
      final owner = await client
          .from('profiles')
          .select('display_name')
          .eq('id', card['owner_id'] as String)
          .single();
      final type = CardType.fromDb(card['card_type'] as String);
      await NotificationService.instance.show(
        NotifChannel.fomo,
        '${owner['display_name']} t\'a envoyé une Vibe',
        '[${type.tag}] ${type.description}',
      );
    } catch (_) {
      // Notification best-effort : ne jamais faire échouer l'app pour ça.
    }
  }

  Future<void> _onLibraryPublished(Map<String, dynamic> record) async {
    final me = ref.read(currentUserIdProvider);
    final ownerId = record['owner_id'] as String?;
    if (ownerId == null || ownerId == me) return;
    try {
      final owner = await ref
          .read(supabaseProvider)
          .from('profiles')
          .select('display_name')
          .eq('id', ownerId)
          .single();
      await NotificationService.instance.show(
        NotifChannel.fomo,
        '${owner['display_name']} a publié',
        'Nouveau contenu dans sa bibliothèque',
      );
    } catch (_) {}
  }

  void _unsubscribe() {
    _channel?.unsubscribe();
  }
}

final fomoListenerProvider = Provider<FomoListener>((ref) {
  // Recrée l'abonnement à chaque changement d'utilisateur connecté
  ref.watch(currentUserIdProvider);
  return FomoListener(ref);
});
