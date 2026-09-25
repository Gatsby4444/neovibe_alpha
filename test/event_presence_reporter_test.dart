import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';
import 'package:neovibe/features/events/event_presence_reporter.dart';
import 'package:neovibe/features/events/events_providers.dart';

/// **Le service de présence ne s'arrête que quand je quitte TOUT événement**
/// (2026-09-25). Le reporter l'arrêtait et le relançait à chaque
/// rafraîchissement de la soirée ; un arrêt arrivé pendant le démarrage, et
/// Android tuait le service (`ForegroundServiceDidNotStartInTimeException`,
/// diagnostic de Jay). Ce test COMPTE les appels au natif.
class _Ou extends Notifier<String?> {
  @override
  String? build() => null;
  void aller(String? id) => state = id;
}

final _ou = NotifierProvider<_Ou, String?>(_Ou.new);

class _Soirees extends Notifier<int> {
  @override
  int build() => 0;
  void rafraichir() => state++;
}

final _version = NotifierProvider<_Soirees, int>(_Soirees.new);

NeoEvent _soiree(String id, int presents) => NeoEvent(
  id: id,
  kind: EventKind.open,
  title: 'Soirée $id',
  createdBy: 'x',
  conversationId: 'c$id',
  startsAt: DateTime(2026, 9, 25),
  membersCanAdd: true,
  membersCanRemove: true,
  presentCount: presents,
  guestCount: 0,
  iAmPresent: true,
  iManage: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'démarré une fois, re-ciblé, arrêté seulement en quittant tout',
    () async {
      final appels = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('neovibe/event_presence'),
            (call) async {
              appels.add(
                call.method == 'start'
                    ? 'start ${(call.arguments as Map)['eventId']}'
                    : call.method,
              );
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('neovibe/event_presence'),
              null,
            ),
      );

      final c = ProviderContainer(
        overrides: [
          currentEventIdProvider.overrideWith((ref) => ref.watch(_ou)),
          // Une soirée dont les informations bougent (un présent de plus…).
          eventByIdProvider.overrideWith(
            (ref, id) => _soiree(id, ref.watch(_version)),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(eventPresenceReporterProvider, (_, _) {}, fireImmediately: true);
      Future<void> tour() => Future<void>.delayed(Duration.zero);

      c.read(_ou.notifier).aller('A');
      await tour();
      expect(appels, ['start A']);

      // La soirée se rafraîchit trois fois : rien ne doit bouger côté natif.
      for (var i = 0; i < 3; i++) {
        c.read(_version.notifier).rafraichir();
        await tour();
      }
      expect(appels, [
        'start A',
      ], reason: 'aucun arrêt sur un rafraîchissement');

      // Une autre soirée : re-ciblé, sans arrêt.
      c.read(_ou.notifier).aller('B');
      await tour();
      expect(appels, ['start A', 'start B']);

      // Plus aucune soirée : arrêté, une fois.
      c.read(_ou.notifier).aller(null);
      await tour();
      expect(appels, ['start A', 'start B', 'stop']);
    },
  );
}
