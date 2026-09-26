import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/palette.dart';
import 'package:neovibe/core/theme.dart';
import 'package:neovibe/features/map/friend_wheel.dart';
import 'package:neovibe/features/map/walking_route.dart';

/// La roue d'actions sur un ami et le trajet à pied (2026-09-26).
void main() {
  group('trajet à pied', () {
    test('la réponse de Mapbox (longitude, latitude) devient un trajet', () {
      final t = WalkingRouteService.parse({
        'routes': [
          {
            'distance': 605.4,
            'duration': 431.0,
            'geometry': {
              'coordinates': [
                [3.0708, 50.6368],
                [3.0633, 50.6372],
              ],
            },
          },
        ],
      })!;
      expect(t.points.first, (50.6368, 3.0708));
      expect(t.libelle, '605 m · 8 min');
    });

    test('au-delà d\'un kilomètre, et au-delà d\'une heure', () {
      const t = WalkingRoute(
        points: [],
        distanceM: 5300,
        duration: Duration(minutes: 65),
      );
      expect(t.libelle, '5,3 km · 1 h 5 min');
    });

    test('pas de trajet : rien', () {
      expect(WalkingRouteService.parse({'routes': []}), isNull);
    });
  });

  testWidgets('la roue : quatre icônes, un tap agit, toucher ailleurs ferme', (
    tester,
  ) async {
    var profil = 0;
    var ferme = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NeoTheme.of(NeoIdentity.sombre, Brightness.dark),
        home: Scaffold(
          body: FriendWheel(
            centre: const Offset(300, 400),
            onClose: () => ferme++,
            actions: [
              FriendWheelAction(
                icone: Icons.person_rounded,
                nom: 'Voir le profil',
                onTap: () => profil++,
              ),
              FriendWheelAction(
                icone: Icons.chat_bubble_rounded,
                nom: 'Message',
                onTap: () {},
              ),
              FriendWheelAction(
                icone: Icons.directions_walk_rounded,
                nom: 'Rejoindre',
                onTap: () {},
              ),
              FriendWheelAction(
                icone: Icons.share_location_rounded,
                nom: 'Demander sa position',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InkWell), findsNWidgets(4));
    // Toutes AU-DESSUS de la photo.
    for (final e in find.byType(InkWell).evaluate()) {
      final box = e.renderObject! as RenderBox;
      expect(box.localToGlobal(Offset.zero).dy, lessThan(400));
    }
    await tester.tap(find.byIcon(Icons.person_rounded));
    expect(profil, 1);
    await tester.tapAt(const Offset(20, 560));
    expect(ferme, 1);
  });
}
