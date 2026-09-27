import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import '../../core/notifications/notification_service.dart';
import '../../core/api/nv_api.dart';
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
    ref.onDispose(() => _ecoute?.cancel());
  }

  final Ref ref;
  StreamSubscription<NvChangement>? _ecoute;

  void _subscribe() {
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;
    _ecoute = ref
        .read(nvDirectProvider)
        .insertions('location_requests', colonne: 'target_id', valeur: me)
        .listen((c) => _onDemande(c.ligne));
  }

  Future<void> _onDemande(Map<String, dynamic> record) async {
    try {
      final qui =
          await ref.read(nvApiProvider).op('profiles_get', {
                'p_id': record['requester_id'] as String,
              })
              as Map<String, dynamic>;
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
