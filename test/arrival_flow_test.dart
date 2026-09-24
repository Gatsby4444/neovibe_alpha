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
  // autoDispose : on garde le parcours vivant pendant le test.
  c.listen(arrivalFlowProvider, (_, _) {});
  return c;
}

void main() {
  test('on ne recule ni avant l\'accroche, ni depuis la soirée', () {
    final c = _container(() async => const []);
    final flow = c.read(arrivalFlowProvider.notifier);

    expect(flow.back(), isFalse);
    flow.goTo(ArrivalStep.selfie);
    expect(flow.back(), isTrue);
    expect(c.read(arrivalFlowProvider).step, ArrivalStep.name);

    flow.goTo(ArrivalStep.inside);
    expect(flow.back(), isFalse);
    expect(c.read(arrivalFlowProvider).step, ArrivalStep.inside);
  });

  test('le prénom est rogné, l\'initiale en majuscule', () {
    final c = _container(() async => const []);
    c.read(arrivalFlowProvider.notifier).setName('  jay ');
    final s = c.read(arrivalFlowProvider);
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
        .read(arrivalFlowProvider.notifier)
        .findVenue(minRadar: Duration.zero);
    final venue = c.read(arrivalFlowProvider).venue!;
    expect(venue.place, 'Le Plus Près');
    expect(venue.isDemo, isFalse);
    expect(c.read(arrivalFlowProvider).searching, isFalse);
  });

  test('sans position ni soirée autour, c\'est la démo — qui le dit', () async {
    for (final nearby in <Future<List<NearbyEvent>> Function()>[
      () async => const [],
      () async => [_event(distance: 5000)],
      () async => throw StateError('Position indisponible'),
    ]) {
      final c = _container(nearby);
      await c
          .read(arrivalFlowProvider.notifier)
          .findVenue(minRadar: Duration.zero);
      expect(c.read(arrivalFlowProvider).venue, ArrivalVenue.demo);
      expect(c.read(arrivalFlowProvider).venue!.isDemo, isTrue);
    }
  });
}
