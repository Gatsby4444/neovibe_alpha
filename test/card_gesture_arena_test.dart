import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/cards/flippable_card.dart';
import 'package:neovibe/features/cards/held_pan.dart';

/// **Qui prend le doigt, et quand** — la règle de Jay du 2026-09-18, après
/// trois essais.
///
/// | Où le doigt se pose | Ce qu'il fait | Ce qui gagne |
/// |---|---|---|
/// | n'importe où | il part **tout de suite** vers le haut | le **défilement** |
/// | n'importe où | il part **tout de suite** à l'horizontale | le **retournement** |
/// | **au centre** | il s'attarde `kTempsDePose`, puis glisse | la **manipulation** |
/// | **sur un bord** | il s'attarde, puis glisse vers le haut | le **défilement** |
///
/// Les deux premières lignes sont ce que Jay a redemandé : *« si je swipe
/// rapidement cela ne retourne plus la card comme avant […] il faut le
/// remettre »*. Les deux dernières sont la nouveauté : une **zone centrale**
/// qui, tenue un instant, donne la carte — et des **bords** qui n'écoutent
/// rien, pour que le défilement soit sûr de lui.
void main() {
  const cardWidth = 300.0;
  const cardHeight = 500.0;

  /// Un doigt avance par petits pas, depuis [depuis] (le centre par défaut).
  ///
  /// ⚠️ **Chaque événement porte son heure.** Dans `flutter_test`, un `moveBy`
  /// sans `timeStamp` vaut zéro : tous les mouvements auraient lieu à
  /// l'instant du contact, et une règle fondée sur le temps ne pourrait
  /// jamais devenir vraie. (Le piège a coûté un diagnostic.)
  Future<void> doigt(
    WidgetTester tester,
    Finder finder,
    Offset total, {
    int steps = 30,
    bool pose = false,
    Alignment depuis = Alignment.center,
  }) async {
    final boite = tester.getRect(finder);
    final depart =
        boite.center +
        Offset(
          depuis.x * boite.width / 2 * 0.9,
          depuis.y * boite.height / 2 * 0.9,
        );
    var t = pose
        ? kTempsDePose + const Duration(milliseconds: 20)
        : Duration.zero;
    final geste = await tester.startGesture(depart);
    if (pose) await tester.pump(t);
    for (var i = 0; i < steps; i++) {
      t += const Duration(milliseconds: 16);
      await geste.moveBy(total / steps.toDouble(), timeStamp: t);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await geste.up();
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

  tearDown(() => scroll.dispose());

  Widget flippable() => FlippableCard(
    key: const ValueKey('card'),
    onSideChanged: sides.add,
    onSideSettled: settled.add,
    front: const ColoredBox(color: Colors.red),
    back: const ColoredBox(color: Colors.blue),
  );

  group('FlippableCard libre dans une liste', () {
    testWidgets('un départ vertical immédiat défile', (tester) async {
      await tester.pumpWidget(harness(card: flippable()));
      await doigt(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(sides, isEmpty);
    });

    testWidgets('un swipe horizontal RAPIDE retourne — sans rien tenir', (
      tester,
    ) async {
      // La demande de Jay du 2026-09-18 : le geste le plus naturel de l'app
      // ne doit rien exiger de plus qu'avant.
      await tester.pumpWidget(harness(card: flippable()));
      await doigt(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(cardWidth, 0),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(settled, [false]);
    });

    testWidgets('au centre, tenu puis glissé : la carte, pas la liste', (
      tester,
    ) async {
      await tester.pumpWidget(harness(card: flippable()));
      await doigt(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(0, -200),
        pose: true,
      );
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        0,
        reason:
            'la zone centrale tenue prend le geste « à la place de scroller »',
      );
    });

    testWidgets('sur le bord, même tenu, le vertical défile', (tester) async {
      await tester.pumpWidget(harness(card: flippable()));
      await doigt(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(0, -200),
        pose: true,
        depuis: Alignment.centerLeft,
      );
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        greaterThan(100),
        reason: 'les bords n\'écoutent pas la pose : ils sont au défilement',
      );
    });
  });

  group('TiltableCard dans une liste', () {
    Widget tiltable() => const TiltableCard(
      key: ValueKey('tilt'),
      child: ColoredBox(color: Colors.red),
    );

    testWidgets('un départ vertical immédiat défile', (tester) async {
      await tester.pumpWidget(harness(card: tiltable()));
      await doigt(
        tester,
        find.byKey(const ValueKey('tilt')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
    });

    testWidgets('au centre, tenu, le geste va à la carte', (tester) async {
      await tester.pumpWidget(harness(card: tiltable()));
      await doigt(
        tester,
        find.byKey(const ValueKey('tilt')),
        const Offset(0, -200),
        pose: true,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
    });
  });

  /// **Le plein écran : par les côtés, et aucun glissement** (Jay,
  /// 2026-09-18). Le défilement est seul à tenir le doigt ; un tap sur un
  /// bord retourne, un tap au milieu ne fait rien à la carte.
  group('FlippableCard par les côtés (plein écran)', () {
    Widget parLesCotes({VoidCallback? onTap}) => FlippableCard(
      key: const ValueKey('card'),
      control: FlipControl.sides,
      onTap: onTap,
      onSideChanged: sides.add,
      onSideSettled: settled.add,
      front: const ColoredBox(color: Colors.red),
      back: const ColoredBox(color: Colors.blue),
    );

    testWidgets('un tap sur le bord droit retourne', (tester) async {
      await tester.pumpWidget(harness(card: parLesCotes()));
      final boite = tester.getRect(find.byKey(const ValueKey('card')));
      await tester.tapAt(Offset(boite.right - 10, boite.center.dy));
      await tester.pumpAndSettle();
      expect(settled, [false]);
      expect(scroll.offset, 0);
    });

    testWidgets('un tap sur le bord gauche retourne aussi, puis revient', (
      tester,
    ) async {
      await tester.pumpWidget(harness(card: parLesCotes()));
      final boite = tester.getRect(find.byKey(const ValueKey('card')));
      await tester.tapAt(Offset(boite.left + 10, boite.center.dy));
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(boite.left + 10, boite.center.dy));
      await tester.pumpAndSettle();
      expect(settled, [false, true]);
    });

    testWidgets('un tap au milieu ne retourne pas, il va à l\'écran', (
      tester,
    ) async {
      var ouvert = 0;
      await tester.pumpWidget(
        harness(card: parLesCotes(onTap: () => ouvert++)),
      );
      await tester.tap(find.byKey(const ValueKey('card')));
      await tester.pumpAndSettle();
      expect(settled, isEmpty);
      expect(ouvert, 1);
    });

    testWidgets('tenu au centre puis glissé : le DÉFILEMENT, pas la carte', (
      tester,
    ) async {
      // Le contre-test du mode geste : là-bas, ce même doigt manipule la
      // carte. Ici, elle n'écoute rien.
      await tester.pumpWidget(harness(card: parLesCotes()));
      await doigt(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(0, -200),
        pose: true,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(sides, isEmpty);
    });

    testWidgets('un swipe horizontal ne retourne pas', (tester) async {
      await tester.pumpWidget(harness(card: parLesCotes()));
      await doigt(
        tester,
        find.byKey(const ValueKey('card')),
        const Offset(cardWidth, 0),
      );
      await tester.pumpAndSettle();
      expect(settled, isEmpty);
    });
  });
}
