import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/cards/flippable_card.dart';

/// Ce que ces tests défendent : **une carte au geste libre dans une liste
/// qui défile** — la décision du 2026-09-15 (geste libre remis partout)
/// repose sur la règle d'arène de Flutter lue dans `gestures/monodrag.dart` :
/// un départ vertical va à la liste (elle accepte à 18 px sur sa seule
/// composante), un départ horizontal va à la carte (elle accepte à 36 px de
/// distance totale). Le 2026-09-14 j'avais affirmé l'inverse sans lire la
/// source ; ces tests empêchent de le réaffirmer.
void main() {
  const cardWidth = 300.0;
  const cardHeight = 500.0;

  /// Un doigt avance par petits pas. `tester.drag` saute d'un coup, et le
  /// reconnaisseur (`DragStartBehavior.start`) ignore tout ce qui précède
  /// son acceptation : la carte ne verrait rien du geste.
  Future<void> dragInSteps(
    WidgetTester tester,
    Finder finder,
    Offset total, {
    int steps = 30,
  }) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(total / steps.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
  }

  late ScrollController scroll;
  final sides = <bool>[];
  final settled = <bool>[];

  Widget harness({required Widget card}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: cardWidth,
          child: ListView(
            controller: scroll,
            children: [
              SizedBox(height: cardHeight, child: card),
              for (var i = 0; i < 5; i++)
                const SizedBox(
                  height: cardHeight,
                  child: ColoredBox(color: Colors.grey),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  setUp(() {
    scroll = ScrollController();
    sides.clear();
    settled.clear();
  });

  group('FlippableCard libre dans une liste', () {
    Widget card() => FlippableCard(
      key: const ValueKey('card'),
      onSideChanged: sides.add,
      onSideSettled: settled.add,
      front: const ColoredBox(color: Colors.red),
      back: const ColoredBox(color: Colors.blue),
    );

    testWidgets('un départ vertical défile, la carte ne bouge pas', (
      tester,
    ) async {
      await tester.pumpWidget(harness(card: card()));
      await dragInSteps(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(sides, isEmpty);
      expect(settled, isEmpty);
    });

    testWidgets('un départ horizontal retourne, la liste ne bouge pas', (
      tester,
    ) async {
      await tester.pumpWidget(harness(card: card()));
      // Une largeur de carte = un demi-tour.
      await dragInSteps(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(cardWidth, 0),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(settled, [false]);
    });
  });

  group('TiltableCard dans une liste', () {
    testWidgets('un départ vertical défile', (tester) async {
      await tester.pumpWidget(
        harness(
          card: const TiltableCard(
            key: ValueKey('card'),
            child: ColoredBox(color: Colors.red),
          ),
        ),
      );
      await dragInSteps(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
    });
  });
}
