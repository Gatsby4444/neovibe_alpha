import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import 'events_providers.dart';

/// **La cuisine du mode événement** : tout ce qui parle au serveur, et rien
/// d'autre. Un écran ne connaît aucun nom de RPC ; il demande ici.
///
/// ⚠️ **L'invalidation appartient à l'ÉCRITURE** (règle de `CLAUDE.md`) :
/// chaque méthode qui change quelque chose laisse les lecteurs dans le bon
/// état elle-même. Deux écrans qui invitent quelqu'un n'ont pas à savoir
/// lequel des providers doit se rafraîchir.
///
/// ⚠️ **Le serveur décide de tout** : qui peut inviter, qui est trop loin,
/// qui ferme. Ces méthodes transmettent, et laissent remonter le refus tel
/// quel — le message d'erreur du serveur est écrit pour être lu.
class EventsRepository {
  EventsRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  // ─── Lectures ───────────────────────────────────────────────────────────

  Future<List<NeoEvent>> myEvents() async {
    final rows = await _client.rpc('my_events') as List;
    return [
      for (final r in rows)
        NeoEvent.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  Future<List<EventPerson>> people(String eventId) async {
    final rows =
        await _client.rpc('event_people', params: {'p_event': eventId}) as List;
    return [
      for (final r in rows)
        EventPerson.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  Future<List<HotSpot>> hotSpots(String eventId) async {
    final rows =
        await _client.rpc('event_hot_spots', params: {'p_event': eventId})
            as List;
    return [
      for (final r in rows)
        HotSpot.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  /// Les soirées à portée : d'établissement et ouvertes (2026-09-21), avec
  /// leur nombre de présents.
  Future<List<NearbyEvent>> nearby(double lat, double lon) async {
    final rows =
        await _client.rpc('nearby_events', params: {'p_lat': lat, 'p_lon': lon})
            as List;
    return [
      for (final r in rows)
        NearbyEvent.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  /// Y ai-je été un jour ? (Une présence, même finie.) Pour la galerie :
  /// un événement privé où j'étais invité sans venir n'est pas un moment.
  Future<bool> wasThere(String eventId) async {
    final me = _client.auth.currentUser!.id;
    final rows = await _client
        .from('event_presences')
        .select('id')
        .eq('event_id', eventId)
        .eq('user_id', me)
        .limit(1);
    return rows.isNotEmpty;
  }

  /// Le récap d'un événement (fini ou en cours) : présents, Vibes, gens
  /// rencontrés, nouveaux amis, amis présents.
  Future<EventRecap> recap(String eventId) async {
    final rows =
        await _client.rpc('event_recap', params: {'p_event': eventId}) as List;
    return EventRecap.fromJson((rows.first as Map).cast<String, dynamic>());
  }

  /// Les défis posés dans un événement, le plus récent d'abord.
  Future<List<EventChallenge>> challenges(String eventId) async {
    final rows = await _client
        .from('event_challenges')
        .select('id, event_id, author_id, text, created_at')
        .eq('event_id', eventId)
        .order('created_at', ascending: false);
    return [for (final r in rows) EventChallenge.fromJson(r)];
  }

  /// Poser un défi : il faut être sur place — le serveur vérifie.
  Future<String> postChallenge(String eventId, String text) async {
    final id =
        await _client.rpc(
              'post_challenge',
              params: {'p_event': eventId, 'p_text': text},
            )
            as String;
    ref.invalidate(eventChallengesProvider(eventId));
    return id;
  }

  // ─── La mémoire des rencontres (2026-09-21) ─────────────────────────────

  /// Qui j'ai rencontré, où, quand — 2 ans, la plus récente d'abord.
  Future<List<Meeting>> myMeetings() async {
    final rows = await _client.rpc('my_meetings') as List;
    return [
      for (final r in rows)
        Meeting.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  /// « Vous vous êtes déjà rencontrés » pour ces personnes : la dernière
  /// rencontre gardée, par personne. Vide = jamais.
  Future<Map<String, MetBefore>> metBefore(Iterable<String> userIds) async {
    final ids = userIds.toSet().toList();
    if (ids.isEmpty) return const {};
    final rows =
        await _client.rpc('met_before', params: {'p_users': ids}) as List;
    return {
      for (final r in rows)
        (r as Map)['user_id'] as String: MetBefore.fromJson(
          r.cast<String, dynamic>(),
        ),
    };
  }

  /// Effacer une rencontre de MA mémoire (l'autre garde la sienne).
  Future<void> forgetMeeting(String meetingId) async {
    await _client.from('meetings').delete().eq('id', meetingId);
    ref.invalidate(myMeetingsProvider);
  }

  // ─── L'événement ouvert (2026-09-21) ────────────────────────────────────

  /// Ouvrir une soirée là où je suis, visible de qui passe à portée. On y
  /// entre sur place, comme chez un établissement. Je suis présent d'office.
  Future<String> createOpen({
    required String title,
    required double lat,
    required double lon,
    required DateTime endsAt,
  }) async {
    final id =
        await _client.rpc(
              'create_open_event',
              params: {
                'p_title': title,
                'p_lat': lat,
                'p_lon': lon,
                'p_ends_at': endsAt.toUtc().toIso8601String(),
              },
            )
            as String;
    _eventsChanged();
    ref.invalidate(nearbyEventsProvider);
    return id;
  }

  // ─── Le groupe d'événement privé ────────────────────────────────────────

  Future<String> createPrivate({
    required String title,
    DateTime? startsAt,
    DateTime? endsAt,
    double? lat,
    double? lon,
    required List<String> memberIds,
  }) => AppLog.instance.trace('create_private_event', () async {
    final id =
        await _client.rpc(
              'create_private_event',
              params: {
                'p_title': title,
                'p_starts_at': (startsAt ?? DateTime.now())
                    .toUtc()
                    .toIso8601String(),
                'p_ends_at': endsAt?.toUtc().toIso8601String(),
                'p_lat': lat,
                'p_lon': lon,
                'p_member_ids': memberIds,
              },
            )
            as String;
    _eventsChanged();
    return id;
  }, details: '${memberIds.length} invité(s)');

  Future<void> invite(String eventId, String userId) async {
    await _client.rpc(
      'invite_to_event',
      params: {'p_event': eventId, 'p_user': userId},
    );
    _peopleChanged(eventId);
  }

  Future<void> remove(String eventId, String userId) async {
    await _client.rpc(
      'remove_from_event',
      params: {'p_event': eventId, 'p_user': userId},
    );
    _peopleChanged(eventId);
  }

  Future<void> setRole(String eventId, String userId, EventRole role) async {
    await _client.rpc(
      'set_event_member_role',
      params: {'p_event': eventId, 'p_user': userId, 'p_role': role.name},
    );
    _peopleChanged(eventId);
  }

  Future<void> updateSettings(
    String eventId, {
    String? title,
    bool? membersCanAdd,
    bool? membersCanRemove,
    DateTime? endsAt,
    double? lat,
    double? lon,
    bool clearPlace = false,
  }) async {
    await _client.rpc(
      'update_event_settings',
      params: {
        'p_event': eventId,
        'p_title': title,
        'p_members_can_add': membersCanAdd,
        'p_members_can_remove': membersCanRemove,
        'p_ends_at': endsAt?.toUtc().toIso8601String(),
        'p_lat': lat,
        'p_lon': lon,
        'p_clear_place': clearPlace,
      },
    );
    _eventsChanged();
  }

  Future<void> close(String eventId) async {
    await _client.rpc('close_event', params: {'p_event': eventId});
    _eventsChanged();
    _peopleChanged(eventId);
  }

  // ─── La présence ────────────────────────────────────────────────────────

  /// Rejoindre EN ÉTANT SUR PLACE. Le serveur refuse si l'on est trop loin,
  /// pas invité, ou si l'événement est fermé — et le dit.
  Future<void> join(
    String eventId, {
    required double lat,
    required double lon,
    double? accuracy,
  }) => AppLog.instance.trace('join_event', () async {
    await _client.rpc(
      'join_event',
      params: {
        'p_event': eventId,
        'p_lat': lat,
        'p_lon': lon,
        'p_acc': accuracy,
      },
    );
    _eventsChanged();
    _peopleChanged(eventId);
  });

  Future<void> leave(String eventId) async {
    await _client.rpc('leave_event', params: {'p_event': eventId});
    _eventsChanged();
    _peopleChanged(eventId);
  }

  // La position pendant l'événement se dépose depuis le NATIF
  // (`EventPresenceService`, 2026-09-21) — un seul écrivain ; l'app ne
  // l'appelle plus d'ici.

  // ─── L'établissement — le contrat de la plateforme ──────────────────────

  Future<String> createVenue({
    required String name,
    required double lat,
    required double lon,
    int radiusM = 60,
    String? address,
  }) async {
    return await _client.rpc(
          'create_venue',
          params: {
            'p_name': name,
            'p_lat': lat,
            'p_lon': lon,
            'p_radius_m': radiusM,
            'p_address': address,
          },
        )
        as String;
  }

  Future<String> openVenueEvent({
    required String venueId,
    required String title,
    required DateTime closesAt,
    DateTime? startsAt,
  }) async {
    final id =
        await _client.rpc(
              'open_venue_event',
              params: {
                'p_venue': venueId,
                'p_title': title,
                'p_closes_at': closesAt.toUtc().toIso8601String(),
                'p_starts_at': (startsAt ?? DateTime.now())
                    .toUtc()
                    .toIso8601String(),
              },
            )
            as String;
    _eventsChanged();
    return id;
  }

  // ─── Invalidation — ici, jamais chez l'appelant ─────────────────────────

  void _eventsChanged() => ref.invalidate(myEventsProvider);

  void _peopleChanged(String eventId) {
    ref.invalidate(eventPeopleProvider(eventId));
    ref.invalidate(myEventsProvider);
  }
}

final eventsRepositoryProvider = Provider((ref) => EventsRepository(ref));
