import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import '../../core/models/card.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/api/nv_api.dart';
import '../../core/session_providers.dart';

/// Écouteur FOMO global (spec 4.9) — sobre : uniquement
/// « [Ami] t'a envoyé une Card [Type] » et « [Ami] a publié ».
/// (« est en train d'écrire » est un indicateur in-app, dans la conversation.)
class FomoListener {
  FomoListener(this.ref) {
    _subscribe();
    ref.onDispose(_unsubscribe);
  }

  final Ref ref;
  final _ecoutes = <StreamSubscription<NvChangement>>[];

  void _subscribe() {
    final direct = ref.read(nvDirectProvider);
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;

    _ecoutes
      // Card reçue — avec le type dans la notification (même tag que la Card)
      ..add(
        direct
            .insertions('card_deliveries', colonne: 'recipient_id', valeur: me)
            .listen((c) => _onCardDelivered(c.ligne)),
      )
      // Publication d'un ami dans sa bibliothèque (visible pour moi : le
      // serveur ne diffuse que ce que la règle de lecture laisse voir)
      ..add(
        direct
            .insertions('library_items')
            .listen((c) => _onLibraryPublished(c.ligne)),
      );
  }

  Future<void> _onCardDelivered(Map<String, dynamic> record) async {
    final api = ref.read(nvApiProvider);
    try {
      final card =
          await api.op('card_get', {'id': record['card_id'] as String})
              as Map<String, dynamic>;
      final owner =
          await api.op('profiles_get', {'p_id': card['owner_id'] as String})
              as Map<String, dynamic>;
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
      final owner =
          await ref.read(nvApiProvider).op('profiles_get', {'p_id': ownerId})
              as Map<String, dynamic>;
      await NotificationService.instance.show(
        NotifChannel.fomo,
        '${owner['display_name']} a publié',
        'Nouveau contenu dans sa bibliothèque',
      );
    } catch (_) {}
  }

  void _unsubscribe() {
    for (final e in _ecoutes) {
      unawaited(e.cancel());
    }
    _ecoutes.clear();
  }
}

final fomoListenerProvider = Provider<FomoListener>((ref) {
  // Recrée l'abonnement à chaque changement d'utilisateur connecté
  ref.watch(currentUserIdProvider);
  return FomoListener(ref);
});
