import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/derived_list.dart';
import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../proximity/geo/live_position.dart';
import 'events_repository.dart';

/// **Les serveurs du mode événement** : des vues dérivées, chacune à son
/// rythme, au-dessus de la cuisine (`events_repository.dart`).
///
/// | Vue | Source | Rythme |
/// |---|---|---|
/// | [myPresencesStreamProvider] | mes lignes de `event_presences`, temps réel | quand j'entre ou je sors |
/// | [currentEventIdProvider] | dérivée de la précédente | seulement si l'identifiant change |
/// | [myEventsProvider] | `my_events()` | à chaque changement de présence, et sur invalidation par la cuisine |
/// | [eventPresencesStreamProvider] | les présences d'UN événement, temps réel | quand quelqu'un entre ou sort |
/// | [eventPeopleProvider] | `event_people()` | à chaque mouvement de présence ou d'invité |
/// | [eventHotSpotsProvider] | `event_hot_spots()` | une fois par minute, et à chaque mouvement |
/// | [eventPeerIdsProvider] | dérivée : qui je peux reconnaître grâce à un événement | seulement si l'ensemble change |
///
/// ⚠️ **Un écran ne lit jamais deux fois la même chose par deux chemins.**
/// « Suis-je dans un événement ? » se demande à [currentEventIdProvider], et
/// nulle part ailleurs.

/// Mes présences, brutes, en temps réel. La SOURCE de « où suis-je ? ».
final myPresencesStreamProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) {
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return Stream.value(const []);
  return client
      .from('event_presences')
      .stream(primaryKey: ['id'])
      .eq('user_id', me)
      .map((rows) => rows.toList(growable: false));
});

/// L'événement où je suis présent **maintenant** — un seul, par construction
/// (index unique côté serveur). Ne notifie que si l'identifiant change.
final currentEventIdProvider = Provider<String?>((ref) {
  final rows = ref.watch(myPresencesStreamProvider).value ?? const [];
  for (final r in rows) {
    if (r['left_at'] == null) return r['event_id'] as String?;
  }
  return null;
});

/// Vrai si je suis dans un événement — c'est ce qui **ouvre le mode
/// événement** dans l'interface (Jay : « il n'apparaît que si tu rejoins un
/// événement »).
final inEventModeProvider = Provider<bool>(
  (ref) => ref.watch(currentEventIdProvider) != null,
);

/// Tous mes événements : invité, présent, ou gérant — tant qu'ils vivent.
final myEventsProvider = FutureProvider<List<NeoEvent>>((ref) async {
  ref.watch(realtimeEpochProvider);
  // Entrer ou sortir change les compteurs : on relit.
  ref.watch(currentEventIdProvider);
  if (ref.watch(currentUserIdProvider) == null) return const [];
  return ref.watch(eventsRepositoryProvider).myEvents();
});

/// UN événement, par son identifiant. Ne notifie que si CET événement change.
final eventByIdProvider = Provider.family<NeoEvent?, String>((ref, id) {
  return ref.watch(
    myEventsProvider.select((async) {
      final list = async.value;
      if (list == null) return null;
      for (final e in list) {
        if (e.id == id) return e;
      }
      return null;
    }),
  );
});

/// L'événement dont [conversationId] est le chat — ou nul (pas un chat
/// d'événement, ou un événement dont je ne suis pas). Sert au chat pour savoir
/// s'il est celui d'un événement **privé** (vocaux autorisés, Jay 2026-09-13)
/// ou d'établissement.
final eventByConversationProvider = Provider.family<NeoEvent?, String>((
  ref,
  conversationId,
) {
  return ref.watch(
    myEventsProvider.select((async) {
      final list = async.value;
      if (list == null) return null;
      for (final e in list) {
        if (e.conversationId == conversationId) return e;
      }
      return null;
    }),
  );
});

/// L'événement où je suis, avec ses détails — ou nul.
final currentEventProvider = Provider<NeoEvent?>((ref) {
  final id = ref.watch(currentEventIdProvider);
  if (id == null) return null;
  return ref.watch(eventByIdProvider(id));
});

/// Les présences d'UN événement, brutes, en temps réel.
final eventPresencesStreamProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, eventId) {
      ref.watch(realtimeEpochProvider);
      final client = ref.watch(supabaseProvider);
      return client
          .from('event_presences')
          .stream(primaryKey: ['id'])
          .eq('event_id', eventId)
          .map((rows) => rows.toList(growable: false));
    });

/// Les invités de tous les groupes d'événement où je suis, bruts.
final eventGroupMembersStreamProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
      ref.watch(realtimeEpochProvider);
      final client = ref.watch(supabaseProvider);
      if (ref.watch(currentUserIdProvider) == null) {
        return Stream.value(const []);
      }
      return client
          .from('event_group_members')
          .stream(primaryKey: ['event_id', 'user_id'])
          .map((rows) => rows.toList(growable: false));
    });

/// Les gens d'un événement — invités et présents, avec leur relation.
final eventPeopleProvider = FutureProvider.family<List<EventPerson>, String>((
  ref,
  eventId,
) async {
  // Quelqu'un entre, sort, est invité ou retiré : on relit la liste.
  ref.watch(eventPresencesStreamProvider(eventId));
  ref.watch(eventGroupMembersStreamProvider);
  return ref.watch(eventsRepositoryProvider).people(eventId);
});

/// Un battement par minute — le rythme des points chauds.
final _minuteProvider = StreamProvider<int>(
  (ref) => Stream.periodic(const Duration(seconds: 60), (i) => i),
);

/// Les points chauds d'un événement : une vue dérivée des positions, que le
/// serveur recalcule. Une fois par minute, et à chaque mouvement de présence.
final eventHotSpotsProvider = FutureProvider.family<List<HotSpot>, String>((
  ref,
  eventId,
) async {
  ref.watch(_minuteProvider);
  ref.watch(eventPresencesStreamProvider(eventId));
  return ref.watch(eventsRepositoryProvider).hotSpots(eventId);
});

/// Les soirées d'établissement autour de moi. Demande une position : sans
/// elle, l'erreur le dit — l'écran n'a pas à deviner.
final nearbyEventsProvider = FutureProvider<List<NearbyEvent>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const [];
  final fix = await ref.read(livePositionProvider.notifier).current();
  if (fix == null) {
    throw StateError('Position indisponible');
  }
  return ref
      .watch(eventsRepositoryProvider)
      .nearby(fix.latitude, fix.longitude);
});

/// **Qui je peux reconnaître grâce à un événement** : les présents de mon
/// événement, et les invités de mes groupes d'événement.
///
/// ⚠️ Cette vue ne décide de rien — c'est le serveur (`key_book`) qui dit qui
/// je reconnais. Elle sert de DÉCLENCHEUR au rapatriement du carnet
/// (`friend_book_watcher.dart`) : quand cet ensemble bouge, le carnet est à
/// relire. `DerivedSet` : ne réveille que si l'ensemble change vraiment.
class _EventPeerIds extends Notifier<Set<String>> with DerivedSet<String> {
  @override
  Set<String> build() {
    final me = ref.watch(currentUserIdProvider);
    final ids = <String>{};
    final current = ref.watch(currentEventIdProvider);
    if (current != null) {
      for (final r
          in ref.watch(eventPresencesStreamProvider(current)).value ??
              const <Map<String, dynamic>>[]) {
        final id = r['user_id'] as String?;
        if (r['left_at'] == null && id != null && id != me) ids.add(id);
      }
    }
    for (final r
        in ref.watch(eventGroupMembersStreamProvider).value ??
            const <Map<String, dynamic>>[]) {
      final id = r['user_id'] as String?;
      if (id != null && id != me) ids.add(id);
    }
    return ids;
  }
}

final eventPeerIdsProvider = NotifierProvider<_EventPeerIds, Set<String>>(
  _EventPeerIds.new,
);

/// Le récap d'un événement : relu à chaque changement de présence.
final eventRecapProvider = FutureProvider.family<EventRecap, String>((
  ref,
  eventId,
) {
  ref.watch(realtimeEpochProvider);
  ref.watch(eventPresencesStreamProvider(eventId));
  return ref.watch(eventsRepositoryProvider).recap(eventId);
});

/// Les défis d'un événement ; la cuisine l'invalide quand elle en pose un.
final eventChallengesProvider =
    FutureProvider.family<List<EventChallenge>, String>(
      (ref, eventId) => ref.watch(eventsRepositoryProvider).challenges(eventId),
    );

/// Ma mémoire des rencontres (2 ans).
final myMeetingsProvider = FutureProvider<List<Meeting>>((ref) {
  ref.watch(realtimeEpochProvider);
  if (ref.watch(currentUserIdProvider) == null) return const [];
  return ref.watch(eventsRepositoryProvider).myMeetings();
});

/// « Déjà rencontré(e) » pour un lot de personnes — une requête pour la liste.
/// ⚠️ La clé est une liste : deux listes égales élément par élément ne sont
/// pas `==` en Dart ; l'appelant passe une liste TRIÉE et la garde stable.
final metBeforeProvider = FutureProvider.family<Map<String, MetBefore>, String>(
  (ref, joinedIds) {
    final ids = joinedIds.isEmpty ? const <String>[] : joinedIds.split(',');
    return ref.watch(eventsRepositoryProvider).metBefore(ids);
  },
);
