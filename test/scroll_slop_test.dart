import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/scroll_slop.dart';
import 'package:neovibe/features/cards/flippable_card.dart';

/// Ce que ce test défend : **un doigt qui part de travers va à la carte, pas
/// au défilement.**
///
/// En plein écran, un défilement déclenché par erreur ne coûte pas trois
/// pixels : il change de Vibe. Jay, 2026-09-17 : *« la marge d'erreur semble
/// plus réduite, il faut vraiment conscientiser le geste »*.
///
/// Les deux reconnaisseurs et leurs seuils (`touchSlop` pour le défilement,
/// `panSlop = touchSlop × 2` pour la carte) sont décrits dans [ScrollSlop].
void main() {
  /// Un `PageView` vertical dont chaque page porte une carte, avec ou sans
  /// la marge élargie. Rend la position de défilement **pendant** le geste.
  Future<double> defilementApres(
    WidgetTester tester, {
    required bool marge,
    required Offset pas,
  }) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    Widget liste = PageView.builder(
      controller: pages,
      scrollDirection: Axis.vertical,
      itemCount: 3,
      itemBuilder: (context, i) {
        const carte = TiltableCard(
          child: SizedBox.expand(child: ColoredBox(color: Colors.blue)),
        );
        return marge ? const DeviceGestures(child: carte) : carte;
      },
    );
    if (marge) liste = ScrollSlop(child: liste);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: liste)));

    final doigt = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    for (var i = 0; i < 12; i++) {
      await doigt.moveBy(pas);
      await tester.pump();
    }
    final pendant = pages.position.pixels;
    await doigt.up();
    await tester.pumpAndSettle();
    return pendant;
  }

  testWidgets('tout droit vers le haut : le défilement gagne, avec ou sans', (
    tester,
  ) async {
    // 12 pas de 6 px = 72 px de montée : au-delà des deux seuils.
    expect(
      await defilementApres(tester, marge: false, pas: const Offset(0, -6)),
      greaterThan(0),
    );
    expect(
      await defilementApres(tester, marge: true, pas: const Offset(0, -6)),
      greaterThan(0),
      reason: 'élargir la marge ne doit pas empêcher de défiler',
    );
  });

  testWidgets(
    'en diagonale à 45° : sans la marge, le défilement vole le geste',
    (tester) async {
      // Contre-test intégré : c'est l'état d'avant, et ce que Jay a ressenti.
      expect(
        await defilementApres(tester, marge: false, pas: const Offset(4, -4)),
        greaterThan(0),
      );
    },
  );

  testWidgets('en diagonale à 45° : avec la marge, la carte garde le geste', (
    tester,
  ) async {
    expect(
      await defilementApres(tester, marge: true, pas: const Offset(4, -4)),
      0,
      reason: 'la page n\'a pas bougé : le geste est allé à la carte',
    );
  });
}
