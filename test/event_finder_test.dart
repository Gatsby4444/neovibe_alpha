import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';
import 'package:neovibe/core/models/profile.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/events/event_finder_screen.dart';
import 'package:neovibe/features/events/events_repository.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/geo/live_position.dart';

/// **Le radar bloqué** (Jay, 2026-09-25 : la soirée à 3 m, « On cherche ta
/// soirée… » pendant 80 minutes). Le VRAI écran et la VRAIE liste
/// (`nearbyEventsProvider`) ; seuls la position (rendue tout de suite) et le
/// serveur (la soirée à 3 m) sont simulés.
///
/// La liste arrive AVANT la fin du temps minimum du radar : c'est le cas où
/// l'ancienne double horloge (`late final _started`) ne redessinait plus
/// jamais l'écran.
class _Position extends LivePosition {
  @override
  Future<CoarseFix?> current() async => const CoarseFix(
    cellLat: 0,
    cellLon: 0,
    latitude: 50.6365,
    longitude: 3.0598,
    accuracy: 20,
    source: FixSource.best,
  );
}

class _Serveur extends EventsRepository {
  _Serveur(super.ref);
  @override
  Future<List<NearbyEvent>> nearby(double lat, double lon) async => [
    NearbyEvent(
      id: 'e',
      kind: EventKind.open,
      title: 'Soirée test de Jay',
      venueName: 'Chez NeoVibe',
      lat: 50.6365,
      lon: 3.0598,
      radiusM: 300,
      startsAt: DateTime(2026, 9, 25),
      presentCount: 1,
      distanceM: 3,
    ),
  ];
}

class _Profil extends MyProfile {
  @override
  Future<Profile?> build() async => null;
}

void main() {
  testWidgets('le radar trouve la soirée à 3 m', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('moi'),
          livePositionProvider.overrideWith(_Position.new),
          eventsRepositoryProvider.overrideWith(_Serveur.new),
          myProfileProvider.overrideWith(_Profil.new),
        ],
        child: const MaterialApp(home: EventFinderScreen()),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('On cherche\nta soirée…'), findsNothing);
    expect(find.text('Chez NeoVibe'), findsOneWidget);
  });
}
