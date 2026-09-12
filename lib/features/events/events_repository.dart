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

  Future<List<NearbyVenueEvent>> nearby(double lat, double lon) async {
    final rows =
        await _client.rpc(
              'nearby_venue_events',
              params: {'p_lat': lat, 'p_lon': lon},
            )
            as List;
    return [
      for (final r in rows)
        NearbyVenueEvent.fromJson((r as Map).cast<String, dynamic>()),
    ];
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

  /// Dépose ma position pendant l'événement. Rend `present`, `away` (le
  /// serveur m'a sorti : trop loin de tout point chaud) ou `none` (je ne suis
  /// dans aucun événement).
  Future<String> reportPosition({
    required double lat,
    required double lon,
    double? accuracy,
  }) async {
    final result =
        await _client.rpc(
              'report_event_position',
              params: {'p_lat': lat, 'p_lon': lon, 'p_acc': accuracy},
            )
            as String?;
    if (result == 'away') _eventsChanged();
    return result ?? 'none';
  }

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
