import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/app_log.dart';
import 'events_providers.dart';

/// **L'ACQUISITION de ma position pendant un événement — côté app.**
///
/// ## Ce que ce service fait, en une phrase
///
/// Tant que je suis dans un événement, il fait tourner le **service natif de
/// présence** (`EventPresenceService`, type `location`) — qui relève ma
/// position une fois par minute et la dépose au serveur, écran éteint, app
/// fermée — et il lit ce que le natif constate. Dès que je n'y suis plus, il
/// l'arrête. C'est tout.
///
/// ## Un seul relevé, une seule écriture (2026-09-21)
///
/// Jusqu'au 2026-09-21, le Dart relevait et déposait lui-même, au premier
/// plan seulement ; le natif est venu pour l'arrière-plan. Deux écrivains
/// pour la même ligne serveur, ç'aurait été un chemin de trop : **le natif
/// dépose, au premier plan aussi**, et ce fichier ne fait que le démarrer,
/// l'arrêter, et l'écouter. Un chemin, une donnée.
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
/// ## La limite, dite
///
/// Le natif ne renouvelle pas le jeton : s'il expire pendant que l'app est
/// fermée, le service s'arrête (`auth`) et le BLE tient la présence via
/// `report_sightings`. Au retour de l'app, ce notifier le relance avec la
/// session fraîche (`main.dart` a rappelé `configure` du pont de
/// publication, dont le natif lit la session).
class EventPresenceReporter extends Notifier<EventReporterState> {
  static const _channel = MethodChannel('neovibe/event_presence');
  static const _events = EventChannel('neovibe/event_presence/events');

  StreamSubscription<dynamic>? _sub;
  String? _started;

  /// ⚠️ **Ne se reconstruit QUE quand l'événement change** (2026-09-25).
  ///
  /// Il lisait aussi le titre de l'événement (`ref.watch(eventByIdProvider)`)
  /// et arrêtait le service dans `ref.onDispose` — or Riverpod appelle
  /// `onDispose` à CHAQUE reconstruction. Chaque rafraîchissement de la
  /// soirée (un présent de plus, une description) faisait donc « arrêter le
  /// service, le relancer » à quelques millisecondes d'écart. Un arrêt arrivé
  /// avant que le service ait fini de démarrer, et Android le tuait :
  /// `ForegroundServiceDidNotStartInTimeException`, relevé au diagnostic de
  /// Jay le 2026-09-25 (08:40). Désormais : le titre se LIT une fois (il ne
  /// sert qu'à la notification), on ne s'arrête que quand je ne suis plus
  /// dans AUCUN événement, et passer d'une soirée à une autre re-cible le
  /// service sans l'arrêter (`EventPresenceService.start` le sait).
  @override
  EventReporterState build() {
    final eventId = ref.watch(currentEventIdProvider);
    if (eventId == null) {
      _stop();
      return const EventReporterState.idle();
    }

    _sub ??= _events.receiveBroadcastStream().listen(
      _onNative,
      onError: (_) {},
    );
    if (_started != eventId) {
      _started = eventId;
      final title = ref.read(eventByIdProvider(eventId))?.title;
      unawaited(_start(eventId, title ?? 'Événement'));
    }
    return EventReporterState.watching(eventId);
  }

  Future<void> _start(String eventId, String title) async {
    try {
      await _channel.invokeMethod('start', {
        'eventId': eventId,
        'title': title,
      });
    } on MissingPluginException {
      // Tests : pas de natif.
    } catch (e) {
      AppLog.instance.error('event_presence', 'démarrage refusé : $e');
    }
  }

  void _stop() {
    if (_started != null) {
      _started = null;
      unawaited(_channel.invokeMethod('stop').catchError((_) => null));
    }
    _sub?.cancel();
    _sub = null;
  }

  void _onNative(dynamic raw) {
    final m = raw as Map<Object?, Object?>;
    final outcome = m['outcome'] as String?;
    if (outcome == null || outcome == 'stopped') return;
    state = state.copyWith(lastOutcome: outcome, lastAt: DateTime.now());
    if (outcome == 'away') {
      // Le serveur m'a sorti : les vues doivent le dire tout de suite.
      ref.invalidate(myEventsProvider);
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

  /// `present`, `away`, `none`, `no_fix`, `offline`, `auth` ou `error`.
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
