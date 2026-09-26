import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/events/map_follow.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/geo/live_position_keeper.dart';

/// Le bouton « recentrer » façon Google Maps, et la position suivie tant
/// qu'un écran est regardé (2026-09-26).
void main() {
  group('MapFollow', () {
    test('libre → centré → boussole → centré', () {
      var m = MapFollow.libre;
      m = m.afterTap(hasHeading: true);
      expect(m, MapFollow.centre);
      m = m.afterTap(hasHeading: true);
      expect(m, MapFollow.boussole);
      m = m.afterTap(hasHeading: true);
      expect(m, MapFollow.centre);
    });

    test('sans boussole, le deuxième appui reste centré', () {
      expect(MapFollow.centre.afterTap(hasHeading: false), MapFollow.centre);
    });

    test('déplacer la carte à la main la libère', () {
      expect(MapFollow.boussole.afterPan, MapFollow.libre);
      expect(MapFollow.libre.follows, isFalse);
      expect(MapFollow.centre.follows, isTrue);
    });
  });

  group('LivePositionKeeper', () {
    testWidgets(
      "tient la position à l'écran, la lâche en arrière-plan et à la sortie",
      (tester) async {
        final faux = _FausseLocalisation();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [coarseLocationProvider.overrideWithValue(faux)],
            child: const MaterialApp(
              home: LivePositionKeeper(child: SizedBox()),
            ),
          ),
        );
        expect(faux.ouverts, 1, reason: "l'écran est regardé");

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(faux.ouverts, 0, reason: "l'app est en arrière-plan");

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(faux.ouverts, 1, reason: 'retour dans l’app');

        await tester.pumpWidget(
          ProviderScope(
            overrides: [coarseLocationProvider.overrideWithValue(faux)],
            child: const MaterialApp(home: SizedBox()),
          ),
        );
        await tester.pump();
        expect(faux.ouverts, 0, reason: "l'écran est fermé");
      },
    );
  });
}

/// Compte les flux de position ouverts : c'est ce qui fait tourner la radio.
class _FausseLocalisation extends CoarseLocation {
  _FausseLocalisation();

  int ouverts = 0;

  @override
  Stream<CoarseFix> watch() {
    late StreamController<CoarseFix> c;
    c = StreamController<CoarseFix>(
      onListen: () => ouverts++,
      onCancel: () => ouverts--,
    );
    return c.stream;
  }

  @override
  Future<LocationPrecision> precision() async => LocationPrecision.precise;
}
