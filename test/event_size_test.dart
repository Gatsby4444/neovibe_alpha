import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';

/// **La taille d'une soirée** (2026-09-25) : « Tu y es » doit dire ce que le
/// serveur accepte — rayon + 30 m de marge (`entry_margin_max_m`), plus les
/// 100 m d'avant qui annonçaient des entrées que le serveur refusait.
void main() {
  NearbyEvent a(int distance, EventSize taille) => NearbyEvent(
    id: 'e',
    kind: EventKind.open,
    title: 'Soirée',
    lat: 0,
    lon: 0,
    radiusM: taille.radiusM,
    startsAt: DateTime(2026),
    presentCount: 0,
    distanceM: distance,
  );

  test('un Bar : à portée jusqu\'à 80 m, plus au-delà', () {
    expect(a(80, EventSize.bar).withinReach, isTrue);
    expect(a(81, EventSize.bar).withinReach, isFalse);
    expect(a(150, EventSize.bar).withinReach, isFalse);
  });

  test('les trois tailles sont celles du serveur', () {
    expect([for (final s in EventSize.values) s.radiusM], [50, 120, 300]);
    expect(EventSize.fromRadius(120), EventSize.grand);
    expect(EventSize.fromRadius(77), isNull);
    expect(EventSize.pleinAir.dbValue, 'plein_air');
  });
}
