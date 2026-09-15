import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/palette.dart';
import 'package:neovibe/core/theme.dart';
import 'package:neovibe/core/widgets/pull_down_to_close.dart';

/// Ce que ces tests défendent : **le geste de fermeture des visionneurs**
/// (Jay, 2026-09-14). Un seuil trop bas ferme l'écran sous un doigt qui
/// hésitait ; trop haut, « le geste ne marche pas » — et ni l'un ni l'autre
/// ne lève d'erreur.
void main() {
  group('la décision, pure', () {
    const h = 800.0;

    test('un quart de l\'écran ferme ; moins, non', () {
      expect(
        PullDownToClose.shouldClose(drag: 200, velocity: 0, height: h),
        isTrue,
      );
      // 🔴 Le contre-test : passer `seuil` à 0.2 fait tomber cette ligne.
      expect(
        PullDownToClose.shouldClose(drag: 199, velocity: 0, height: h),
        isFalse,
      );
    });

    test('un coup sec vers le bas ferme, même court', () {
      expect(
        PullDownToClose.shouldClose(drag: 30, velocity: 900, height: h),
        isTrue,
      );
      // Sans déplacement du tout, la vitesse seule ne compte pas.
      expect(
        PullDownToClose.shouldClose(drag: 0, velocity: 900, height: h),
        isFalse,
      );
      // Vers le haut : jamais.
      expect(
        PullDownToClose.shouldClose(drag: 30, velocity: -2000, height: h),
        isFalse,
      );
    });

    test('l\'échelle descend avec le geste, bornée à 85 %', () {
      expect(PullDownToClose.scaleFor(drag: 0, height: h), 1);
      expect(
        PullDownToClose.scaleFor(drag: 200, height: h),
        closeTo(0.925, 1e-9),
      );
      expect(
        PullDownToClose.scaleFor(drag: 400, height: h),
        closeTo(0.85, 1e-9),
      );
      expect(
        PullDownToClose.scaleFor(drag: 2000, height: h),
        closeTo(0.85, 1e-9),
      );
    });
  });

  group('le geste, en vrai', () {
    Future<int> pomper(WidgetTester tester, {required double dy}) async {
      var fermes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NeoTheme.of(NeoIdentity.sombre, Brightness.dark),
          home: PullDownToClose(
            onClose: () => fermes++,
            child: const Scaffold(
              backgroundColor: Colors.black,
              body: Center(child: Text('vibe')),
            ),
          ),
        ),
      );
      final h = tester.getSize(find.byType(PullDownToClose)).height;
      await tester.drag(find.text('vibe'), Offset(0, dy * h));
      await tester.pumpAndSettle();
      return fermes;
    }

    testWidgets('tirer un tiers de l\'écran ferme', (tester) async {
      expect(await pomper(tester, dy: 0.34), 1);
    });

    testWidgets('tirer un dixième revient en place, sans fermer', (
      tester,
    ) async {
      expect(await pomper(tester, dy: 0.1), 0);
      // Revenu à sa place : le texte est là où il était.
      final centre = tester.getCenter(find.text('vibe'));
      final ecran = tester.getSize(find.byType(PullDownToClose));
      expect(centre.dy, closeTo(ecran.height / 2, 1));
    });

    testWidgets('tirer vers le haut ne fait rien', (tester) async {
      expect(await pomper(tester, dy: -0.5), 0);
    });
  });
}
