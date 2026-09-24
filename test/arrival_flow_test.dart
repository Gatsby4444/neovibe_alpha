import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';
import 'package:neovibe/features/arrival/arrival_flow.dart';
import 'package:neovibe/features/events/events_providers.dart';

NearbyEvent _event({required int distance, int radius = 60, String? venue}) =>
    NearbyEvent(
      id: 'e$distance',
      kind: EventKind.venue,
      title: 'Soirée $distance',
      venueName: venue,
      lat: 0,
      lon: 0,
      radiusM: radius,
      startsAt: DateTime.utc(2026, 9, 24),
      presentCount: 12,
      distanceM: distance,
    );

ProviderContainer _container(Future<List<NearbyEvent>> Function() nearby) {
  final c = ProviderContainer(
    overrides: [nearbyEventsProvider.overrideWith((ref) => nearby())],
  );
  addTearDown(c.dispose);
  c.listen(arrivalFlowProvider(ArrivalMode.test), (_, _) {});
  return c;
}

void main() {
  test('on ne recule ni avant l\'accroche, ni depuis la soirée', () {
    final c = _container(() async => const []);
    final flow = c.read(arrivalFlowProvider(ArrivalMode.test).notifier);

    expect(flow.back(), isFalse);
    flow.goTo(ArrivalStep.selfie);
    expect(flow.back(), isTrue);
    expect(
      c.read(arrivalFlowProvider(ArrivalMode.test)).step,
      ArrivalStep.name,
    );

    flow.goTo(ArrivalStep.inside);
    expect(flow.back(), isFalse);
    expect(
      c.read(arrivalFlowProvider(ArrivalMode.test)).step,
      ArrivalStep.inside,
    );
  });

  test('le prénom est rogné, l\'initiale en majuscule', () {
    final c = _container(() async => const []);
    c.read(arrivalFlowProvider(ArrivalMode.test).notifier).setName('  jay ');
    final s = c.read(arrivalFlowProvider(ArrivalMode.test));
    expect(s.firstName, 'jay');
    expect(s.initial, 'J');
  });

  test('la soirée la plus proche À PORTÉE est retenue', () async {
    final c = _container(
      () async => [
        _event(distance: 900, venue: 'Trop loin'),
        _event(distance: 80, venue: 'Le Bar'),
        _event(distance: 20, venue: 'Le Plus Près'),
      ],
    );
    await c
        .read(arrivalFlowProvider(ArrivalMode.test).notifier)
        .findVenue(minRadar: Duration.zero);
    final venue = c.read(arrivalFlowProvider(ArrivalMode.test)).venue!;
    expect(venue.place, 'Le Plus Près');
    expect(venue.isDemo, isFalse);
    expect(c.read(arrivalFlowProvider(ArrivalMode.test)).searching, isFalse);
  });

  test('sans position ni soirée autour, c\'est la démo — qui le dit', () async {
    for (final nearby in <Future<List<NearbyEvent>> Function()>[
      () async => const [],
      () async => [_event(distance: 5000)],
      () async => throw StateError('Position indisponible'),
    ]) {
      final c = _container(nearby);
      await c
          .read(arrivalFlowProvider(ArrivalMode.test).notifier)
          .findVenue(minRadar: Duration.zero);
      expect(
        c.read(arrivalFlowProvider(ArrivalMode.test)).venue,
        ArrivalVenue.demo,
      );
      expect(
        c.read(arrivalFlowProvider(ArrivalMode.test)).venue!.isDemo,
        isTrue,
      );
    }
  });

  group('mode réel', () {
    test("« J'entre » ouvre l'inscription ; revenir à l'accroche la ferme", () {
      final c = _container(() async => const []);
      final flow = c.read(arrivalFlowProvider(ArrivalMode.real).notifier);
      c.listen(arrivalFlowProvider(ArrivalMode.real), (_, _) {});

      flow.begin(hasAccount: false);
      var s = c.read(arrivalFlowProvider(ArrivalMode.real));
      expect(s.active, isTrue);
      expect(s.step, ArrivalStep.name);

      expect(flow.back(), isTrue);
      s = c.read(arrivalFlowProvider(ArrivalMode.real));
      expect(s.step, ArrivalStep.threshold);
      expect(s.active, isFalse, reason: "plus d'inscription en cours");
    });

    test('déjà connecté : pas de retour avant le prénom', () {
      final c = _container(() async => const []);
      final flow = c.read(arrivalFlowProvider(ArrivalMode.real).notifier);
      c.listen(arrivalFlowProvider(ArrivalMode.real), (_, _) {});
      flow.begin(hasAccount: true);
      expect(flow.back(), isFalse);
    });

    test('une fois aux autorisations, on ne revient plus au compte', () {
      final c = _container(() async => const []);
      final flow = c.read(arrivalFlowProvider(ArrivalMode.real).notifier);
      c.listen(arrivalFlowProvider(ArrivalMode.real), (_, _) {});
      flow.begin(hasAccount: false);
      flow.goTo(ArrivalStep.permissions);
      expect(flow.back(), isFalse);
    });

    test("le test et l'inscription ne partagent pas leur mémoire", () {
      final c = _container(() async => const []);
      c.listen(arrivalFlowProvider(ArrivalMode.real), (_, _) {});
      c
          .read(arrivalFlowProvider(ArrivalMode.real).notifier)
          .begin(hasAccount: false);
      c.read(arrivalFlowProvider(ArrivalMode.test).notifier).setName('Test');
      expect(c.read(arrivalFlowProvider(ArrivalMode.real)).firstName, '');
      expect(c.read(arrivalFlowProvider(ArrivalMode.test)).active, isFalse);
    });

    test('la fin ouvre le radar UNE fois, et remet le parcours à zéro', () {
      final c = _container(() async => const []);
      c.listen(arrivalFlowProvider(ArrivalMode.real), (_, _) {});
      final flow = c.read(arrivalFlowProvider(ArrivalMode.real).notifier);
      flow.begin(hasAccount: true);
      flow.finish();
      expect(c.read(arrivalFlowProvider(ArrivalMode.real)).active, isFalse);
      final wants = c.read(arrivalWantsFinderProvider.notifier);
      expect(wants.take(), isTrue);
      expect(wants.take(), isFalse);
    });
  });
}
