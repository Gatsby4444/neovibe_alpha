import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';
import 'package:neovibe/core/models/profile.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/connections/connections_repository.dart';
import 'package:neovibe/features/events/event_finder_screen.dart';
import 'package:neovibe/features/events/events_repository.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/geo/live_position.dart';

/// **Le radar « Trouver ma soirée »** — le VRAI écran et la VRAIE liste
/// (`nearbyEventsProvider`) ; seuls la position (rendue tout de suite), le
/// serveur et mes amis sont simulés.
///
/// 1. **Le radar bloqué** (Jay, 2026-09-25 : soirée à 3 m, « On cherche ta
///    soirée… » pendant 80 minutes). La liste arrive AVANT la fin du temps
///    minimum : c'est le cas où l'ancienne double horloge (`late final
///    _started`) ne redessinait plus jamais l'écran.
/// 2. **Le paquet des soirées** (même jour) : de la plus proche à la plus
///    lointaine, mes amis présents nommés, le bouton qui suit la carte.
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

NearbyEvent soiree(
  String id,
  String lieu, {
  required int distance,
  List<String> amis = const [],
}) => NearbyEvent(
  id: id,
  kind: EventKind.open,
  title: 'Soirée $id',
  venueName: lieu,
  lat: 50.6365,
  lon: 3.0598,
  radiusM: 300,
  startsAt: DateTime(2026, 9, 25),
  presentCount: 1 + amis.length,
  distanceM: distance,
  friendsPresent: amis,
);

class _Serveur extends EventsRepository {
  _Serveur(super.ref, this.soirees);
  final List<NearbyEvent> soirees;
  @override
  Future<List<NearbyEvent>> nearby(double lat, double lon) async => soirees;
}

class _Profil extends MyProfile {
  @override
  Future<Profile?> build() async => null;
}

Future<void> ouvrir(
  WidgetTester tester,
  List<NearbyEvent> soirees, {
  Map<String, Profile> amis = const {},
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWithValue('moi'),
        livePositionProvider.overrideWith(_Position.new),
        eventsRepositoryProvider.overrideWith((ref) => _Serveur(ref, soirees)),
        myProfileProvider.overrideWith(_Profil.new),
        friendProfilesProvider.overrideWith((ref) async => amis),
      ],
      child: const MaterialApp(home: EventFinderScreen()),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  testWidgets('le radar trouve la soirée à 3 m (ne tourne pas pour toujours)', (
    tester,
  ) async {
    await ouvrir(tester, [soiree('a', 'Chez NeoVibe', distance: 3)]);
    expect(find.text('On cherche\nta soirée…'), findsNothing);
    expect(find.text('Chez NeoVibe'), findsOneWidget);
    expect(find.text('Rejoindre la soirée'), findsOneWidget);
  });

  testWidgets('le paquet : du plus proche au plus loin, amis nommés, swipe', (
    tester,
  ) async {
    await ouvrir(
      tester,
      // Dans le désordre : l'écran doit les ranger.
      [
        soiree('loin', 'Le Loin', distance: 900),
        soiree('ici', 'Chez NeoVibe', distance: 3, amis: ['lea']),
        soiree('pres', 'Le Bar', distance: 150),
      ],
      amis: const {'lea': Profile(id: 'lea', displayName: 'lea')},
    );
    expect(find.text('3 soirées autour de toi'), findsOneWidget);
    // La plus proche en premier, avec mon amie présente.
    expect(find.text('Chez NeoVibe'), findsOneWidget);
    expect(find.text('lea y est'), findsOneWidget);
    expect(find.text('Rejoindre la soirée'), findsOneWidget);

    // Deux cartes plus loin : hors de portée, le bouton le dit.
    for (var i = 0; i < 2; i++) {
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
    }
    expect(find.text('Approche-toi · à 900 m'), findsOneWidget);
  });
}
