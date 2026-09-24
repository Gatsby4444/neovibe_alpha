import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import 'events_providers.dart';

/// **Les notifications d'événement** (étape 5 du programme du 2026-09-21) :
/// « Alice est arrivée », « la soirée est finie — voir le récap », « un
/// moment s'est ouvert avec tes amis ».
///
/// ## Ce qu'il fait, et ce qu'il ne peut pas faire
///
/// Il écoute les vues en temps réel que l'app tient déjà (`my_events`,
/// les présences de l'événement où je suis) et **compare à ce qu'il a vu la
/// fois d'avant** ; une différence = une notification locale. Il ne
/// demande rien de plus au serveur.
///
/// ⚠️ **App vivante seulement.** NeoVibe n'a pas de notification poussée par
/// le serveur (aucun FCM) : app tuée, rien n'arrive. C'est dit dans
/// `docs/evenements.md` ; « une soirée s'ouvre près de toi » exigerait en
/// plus la position en continu hors événement, sorti du scope.
///
/// Rien n'est notifié quand l'app est **au premier plan** : l'écran le
/// montre déjà (les présents se mettent à jour, le bandeau d'événement
/// aussi) ; une notification en plus serait du bruit.
class EventNotifier {
  EventNotifier(this.ref) {
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) => _foreground = s == AppLifecycleState.resumed,
    );
    ref.onDispose(() => _lifecycle.dispose());
    _watch();
  }

  final Ref ref;
  late final AppLifecycleListener _lifecycle;
  var _foreground = true;

  /// Les présents de l'événement en cours, tels que vus la dernière fois.
  Set<String>? _lastPresent;
  String? _lastEventId;

  /// Mes événements ouverts, tels que vus la dernière fois (pour dire
  /// « fini » et « un moment s'est ouvert »).
  Map<String, NeoEvent>? _lastEvents;

  void _watch() {
    ref.listen<String?>(currentEventIdProvider, (_, id) {
      if (id != _lastEventId) {
        _lastEventId = id;
        _lastPresent = null;
      }
    });

    ref.listen<AsyncValue<List<Map<String, dynamic>>>>(
      _currentPresencesProvider,
      (_, next) => _onPresences(next.value),
    );

    ref.listen<AsyncValue<List<NeoEvent>>>(
      myEventsProvider,
      (_, next) => _onEvents(next.value),
    );
  }

  Future<void> _onPresences(List<Map<String, dynamic>>? rows) async {
    if (rows == null) return;
    final me = ref.read(currentUserIdProvider);
    final now = {
      for (final r in rows)
        if (r['left_at'] == null && r['user_id'] != me) r['user_id'] as String,
    };
    final before = _lastPresent;
    _lastPresent = now;
    if (before == null || _foreground) return;
    final arrivals = now.difference(before);
    if (arrivals.isEmpty) return;
    final friends = ref.read(friendProfilesProvider).value ?? const {};
    final noms = [
      for (final id in arrivals)
        if (friends[id] != null) friends[id]!.chatName,
    ];
    // Seuls mes AMIS sont nommés : un inconnu de soirée reste un présent,
    // pas quelqu'un dont on m'annonce l'arrivée (états de relation, #99).
    if (noms.isEmpty) return;
    final titre = noms.length == 1
        ? '${noms.first} est là'
        : '${noms.take(2).join(' et ')}${noms.length > 2 ? ' et ${noms.length - 2} autre${noms.length > 3 ? 's' : ''}' : ''} sont là';
    await NotificationService.instance.show(
      NotifChannel.fomo,
      titre,
      'Dans l\'événement où tu es.',
      id: _idFor('arrival'),
    );
  }

  Future<void> _onEvents(List<NeoEvent>? events) async {
    if (events == null) return;
    final now = {for (final e in events) e.id: e};
    final before = _lastEvents;
    _lastEvents = now;
    if (before == null || _foreground) return;

    for (final e in now.values) {
      final prev = before[e.id];
      // Un moment s'est ouvert avec mes amis.
      if (prev == null && e.autoCreated && e.isOpen) {
        await NotificationService.instance.show(
          NotifChannel.fomo,
          'Un moment s\'est ouvert',
          '${e.title} — vos Vibes iront dans son Drop.',
          id: _idFor('moment'),
        );
      }
      // Un événement où j'étais vient de se fermer : le récap est là.
      if (prev != null && prev.isOpen && e.isClosed && prev.iAmPresent) {
        await NotificationService.instance.show(
          NotifChannel.fomo,
          '${e.title} — c\'est fini',
          'Ton générique de soirée t\'attend. Le Drop reste cinq jours.',
          id: _idFor('closed'),
          // Toucher ouvre le générique (`main.dart`, `EventRecapScreen`).
          payload: 'recap:${e.id}',
        );
      }
    }
  }

  static int _idFor(String kind) => switch (kind) {
    'arrival' => 3101,
    'moment' => 3102,
    _ => 3103,
  };
}

/// Les présences de l'événement où je suis (vide si je n'en ai pas).
final _currentPresencesProvider =
    Provider<AsyncValue<List<Map<String, dynamic>>>>((ref) {
      final id = ref.watch(currentEventIdProvider);
      if (id == null) return const AsyncValue.data([]);
      return ref.watch(eventPresencesStreamProvider(id));
    });

final eventNotifierProvider = Provider<EventNotifier>((ref) {
  return EventNotifier(ref);
});
