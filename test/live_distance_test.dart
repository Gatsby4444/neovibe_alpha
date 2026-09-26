import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/events/events_providers.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/geo/live_position.dart';

/// La distance à une soirée, en temps réel (Jay, 2026-09-26) : elle suit ma
/// position au lieu de rester figée sur celle du serveur.
void main() {
  CoarseFix fix(double lat, double lon) => CoarseFix(
    cellLat: 5019,
    cellLon: 384,
    latitude: lat,
    longitude: lon,
    accuracy: 10,
    source: FixSource.best,
  );

  test('elle bouge quand je marche vers la soirée', () async {
    final flux = StreamController<CoarseFix>.broadcast();
    final c = ProviderContainer(
      overrides: [coarseLocationProvider.overrideWithValue(_Faux(flux.stream))],
    );
    addTearDown(c.dispose);
    addTearDown(flux.close);
    const gare = (50.19741, 3.84339);
    final lu = <int?>[];
    c.listen(liveDistanceProvider(gare), (_, d) => lu.add(d));
    expect(c.read(liveDistanceProvider(gare)), isNull, reason: 'pas de relevé');

    c.read(livePositionProvider.notifier).acquire();
    await Future<void>.delayed(Duration.zero);
    flux.add(fix(50.20641, 3.84339)); // ~1 km au nord
    await Future<void>.delayed(Duration.zero);
    expect(c.read(liveDistanceProvider(gare)), closeTo(1001, 5));

    flux.add(fix(50.20191, 3.84339)); // ~500 m : je me suis approché
    await Future<void>.delayed(Duration.zero);
    expect(c.read(liveDistanceProvider(gare)), closeTo(500, 5));
    // Et ceux qui l'écoutent sont prévenus, sans relire.
    await Future<void>.delayed(Duration.zero);
    expect(lu.last, closeTo(500, 5));
  });
}

class _Faux extends CoarseLocation {
  const _Faux(this.flux);
  final Stream<CoarseFix> flux;

  @override
  Stream<CoarseFix> watch() => flux;

  @override
  Future<LocationPrecision> precision() async => LocationPrecision.precise;
}
