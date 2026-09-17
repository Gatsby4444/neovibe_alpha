import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/cards/flippable_card.dart';
import 'package:neovibe/features/cards/held_pan.dart';

/// Ce que ces tests défendent : **ce qui départage une carte d'une liste,
/// c'est le TEMPS DE POSE** (Jay, 2026-09-17).
///
/// Deux métriques ont été essayées avant, et rejetées à l'usage : la distance
/// seule (la liste volait les gestes de carte), puis un seuil de défilement
/// élargi (la carte volait les défilements — *« le nouveau système est
/// pire »*). La troisième est la bonne parce qu'elle ne mesure pas le geste
/// mais l'**intention** : on effleure pour défiler, on saisit pour manipuler.
///
/// Règle : un doigt qui part **avant** `kTempsDePose` ne peut pas emmener la
/// carte ; après, il le peut (voir `HeldPanGestureRecognizer`).
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
    // Le doigt se pose, s'attarde, puis glisse : c'est ce qui donne la carte.
    // `pose: false` = il part tout de suite, c'est un défilement.
    bool pose = true,
  }) async {
    // ⚠️ **Chaque événement porte son heure.** Dans `flutter_test`, un
    // `moveBy` sans `timeStamp` vaut zéro : tous les mouvements auraient lieu
    // au même instant que le contact, et une règle fondée sur le temps ne
    // pourrait jamais devenir vraie. (Le piège a coûté un diagnostic.)
    var t = pose
        ? kTempsDePose + const Duration(milliseconds: 20)
        : Duration.zero;
    final gesture = await tester.startGesture(tester.getCenter(finder));
    if (pose) await tester.pump(t);
    for (var i = 0; i < steps; i++) {
      t += const Duration(milliseconds: 16);
      await gesture.moveBy(total / steps.toDouble(), timeStamp: t);
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

  testWidgets('sans le temps de pose, l\'horizontale ne retourne PLUS rien', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        card: FlippableCard(
          key: const ValueKey('card'),
          onSideChanged: sides.add,
          onSideSettled: settled.add,
          front: const ColoredBox(color: Colors.red),
          back: const ColoredBox(color: Colors.blue),
        ),
      ),
    );
    // Contre-test de la règle : le doigt part immédiatement — la carte ne
    // doit pas s'en saisir, même à l'horizontale.
    await dragInSteps(
      tester,
      find.byType(FlippableCard),
      const Offset(220, 0),
      pose: false,
    );
    await tester.pumpAndSettle();
    expect(
      settled,
      isEmpty,
      reason: 'un geste bref n\'appartient pas à la carte',
    );
  });
}
