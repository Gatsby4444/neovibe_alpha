import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/app_log.dart';
import '../proximity/geo/coarse_location.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **L'ACQUISITION de ma position pendant un événement.**
///
/// ## Ce que ce service fait, en une phrase
///
/// Tant que je suis dans un événement et que l'app est au premier plan, il
/// dépose ma position au serveur **une fois par minute**, tout de suite au
/// retour au premier plan, et tout de suite quand j'entre dans l'événement.
/// C'est tout. Il ne décide ni si je suis loin, ni si je suis sorti : c'est
/// le serveur qui compare aux points chauds (`report_event_position`) et
/// qui répond `away` — la réponse est transmise, pas interprétée.
///
/// ## Pourquoi c'est un objet à part
///
/// Le ping des inconnus (`ping_beacon_service.dart`) publie AUSSI une
/// position, mais à un kilomètre près, à un autre rythme, et seulement quand
/// l'écran Ping est ouvert. Deux sources qui ne changent pas au même rythme
/// ne partagent pas le même objet (règle « dissocier l'acquisition de
/// l'usage », point 3). Ici la position est précise, et elle ne sert QU'À
/// l'événement.
///
/// ## ⚠️ Premier plan seulement — la limite, dite
///
/// Android exige un service de premier plan de type « location » pour
/// relever une position app fermée ; ce n'est pas construit (consigné dans
/// `RAPPELS.md`). Entre deux relevés, c'est l'autre preuve du système mixte
/// qui tient : le BLE en arrière-plan entend les co-participants
/// (`report_sightings` → `last_ping_at`). Sans aucune des deux pendant
/// `away_after`, le serveur nous sort — c'est voulu, et c'est réglable.
class EventPresenceReporter extends Notifier<EventReporterState> {
  static const every = Duration(seconds: 60);

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _busy = false;

  @override
  EventReporterState build() {
    final eventId = ref.watch(currentEventIdProvider);

    ref.onDispose(_stop);

    if (eventId == null) {
      _stop();
      return const EventReporterState.idle();
    }

    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(_report()));
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => unawaited(_report()));
    Future.microtask(_report);
    return EventReporterState.watching(eventId);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  Future<void> _report() async {
    if (_busy) return;
    _busy = true;
    try {
      final fix = await ref.read(coarseLocationProvider).current();
      if (fix == null) {
        state = state.copyWith(lastOutcome: 'no_fix', lastAt: DateTime.now());
        return;
      }
      final outcome = await ref
          .read(eventsRepositoryProvider)
          .reportPosition(
            lat: fix.latitude,
            lon: fix.longitude,
            accuracy: fix.accuracy,
          );
      state = state.copyWith(lastOutcome: outcome, lastAt: DateTime.now());
    } catch (e) {
      AppLog.instance.error('event_position', 'dépôt refusé : $e');
      state = state.copyWith(lastOutcome: 'error', lastAt: DateTime.now());
    } finally {
      _busy = false;
    }
  }
}

/// Ce que le service constate — pour le diagnostic, pas pour décider.
@immutable
class EventReporterState {
  const EventReporterState({
    required this.eventId,
    this.lastOutcome,
    this.lastAt,
  });

  const EventReporterState.idle() : this(eventId: null);
  const EventReporterState.watching(String id) : this(eventId: id);

  final String? eventId;

  /// `present`, `away`, `none`, `no_fix` ou `error`.
  final String? lastOutcome;
  final DateTime? lastAt;

  bool get active => eventId != null;

  EventReporterState copyWith({String? lastOutcome, DateTime? lastAt}) =>
      EventReporterState(
        eventId: eventId,
        lastOutcome: lastOutcome ?? this.lastOutcome,
        lastAt: lastAt ?? this.lastAt,
      );

  @override
  bool operator ==(Object other) =>
      other is EventReporterState &&
      other.eventId == eventId &&
      other.lastOutcome == lastOutcome &&
      other.lastAt == lastAt;

  @override
  int get hashCode => Object.hash(eventId, lastOutcome, lastAt);
}

final eventPresenceReporterProvider =
    NotifierProvider<EventPresenceReporter, EventReporterState>(
      EventPresenceReporter.new,
    );
