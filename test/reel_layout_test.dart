import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/vibe_face.dart';
import 'package:neovibe/features/library/feed/vibes_reel_screen.dart';

/// Une fausse carte : le même format qu'une Vibe (9:16 plus son cadre), sans
/// rien qui ait besoin du réseau ni d'une clé.
Widget _carte() => Container(
  key: const ValueKey('carte'),
  margin: const EdgeInsets.all(16),
  padding: const EdgeInsets.all(2.5),
  child: const AspectRatio(
    aspectRatio: kVibeFaceRatio,
    child: ColoredBox(color: Colors.blue),
  ),
);

Widget _actions() => const Column(
  key: ValueKey('actions'),
  mainAxisSize: MainAxisSize.min,
  children: [
    SizedBox(width: 48, height: 48),
    SizedBox(width: 48, height: 48),
    SizedBox(width: 48, height: 48),
  ],
);

Future<void> _poser(
  WidgetTester tester, {
  Size ecran = const Size(411, 731),
}) async {
  tester.view.physicalSize = ecran;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ReelLayout(
          card: _carte(),
          actions: _actions(),
          author: const Text('Charles', key: ValueKey('auteur')),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('les actions ne passent jamais par-dessus la carte', (
    tester,
  ) async {
    await _poser(tester);

    final carte = tester.getRect(find.byKey(const ValueKey('carte')));
    final actions = tester.getRect(find.byKey(const ValueKey('actions')));

    // Le défaut du 2026-09-16 : le cœur au milieu de l'image, le marque-page
    // à cheval sur le bord. La gouttière commence où la carte finit.
    expect(carte.right, lessThanOrEqualTo(actions.left));
    // Et elles restent à l'écran.
    expect(actions.right, lessThanOrEqualTo(411));
  });

  testWidgets('l\'auteur est sous la carte, jamais dessus', (tester) async {
    await _poser(tester);

    final carte = tester.getRect(find.byKey(const ValueKey('carte')));
    final auteur = tester.getRect(find.byKey(const ValueKey('auteur')));
    expect(carte.bottom, lessThanOrEqualTo(auteur.top));
  });

  testWidgets('la croix garde sa bande : la carte ne monte pas dessous', (
    tester,
  ) async {
    await _poser(tester);
    final carte = tester.getRect(find.byKey(const ValueKey('carte')));
    expect(carte.top, greaterThanOrEqualTo(kReelTopBar));
  });

  testWidgets('la carte prend tout ce qui reste, sur un écran large', (
    tester,
  ) async {
    await _poser(tester, ecran: const Size(411, 731));
    final carte = tester.getRect(find.byKey(const ValueKey('carte')));
    // Elle occupe la largeur disponible moins la gouttière — pas moins.
    expect(carte.width, moreOrLessEquals(411 - kReelActionsGutter, epsilon: 1));
  });

  testWidgets('sur un écran court, c\'est la hauteur qui borne la carte', (
    tester,
  ) async {
    await _poser(tester, ecran: const Size(411, 500));
    final carte = tester.getRect(find.byKey(const ValueKey('carte')));
    final actions = tester.getRect(find.byKey(const ValueKey('actions')));
    // La carte a rétréci pour tenir : aucun débordement, aucun chevauchement.
    expect(carte.width, lessThan(411 - kReelActionsGutter));
    expect(carte.right, lessThanOrEqualTo(actions.left));
    expect(carte.bottom, lessThanOrEqualTo(500));
  });
}
