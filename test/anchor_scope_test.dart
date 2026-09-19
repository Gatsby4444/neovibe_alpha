import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/anchor_scope.dart';
import 'package:neovibe/core/widgets/pinch_to_close.dart';

/// **La rétraction vise la cellule** (Jay, 2026-09-19) : le registre de
/// positions dit où est un contenu, et le pincement glisse la forme vers
/// cette boîte au lieu du centre de l'écran.
void main() {
  testWidgets('le registre connaît la boîte d\'un contenu posé, et transmet '
      '« montre-le »', (tester) async {
    final key = GlobalKey<AnchorScopeState>();
    final montres = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AnchorScope(
          key: key,
          onReveal: montres.add,
          child: Stack(
            children: const [
              Positioned(
                left: 100,
                top: 200,
                width: 120,
                height: 150,
                child: Anchored(
                  id: 'c1',
                  child: ColoredBox(color: Colors.red),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final scope = key.currentState!;
    expect(scope.rectOf('c1'), const Rect.fromLTWH(100, 200, 120, 150));
    expect(scope.rectOf('inconnu'), isNull);
    scope.reveal('c1');
    expect(montres, ['c1']);
  });

  testWidgets('avec une cible, le pincement glisse la forme vers elle', (
    tester,
  ) async {
    // La cellule visée : en bas à droite de l'écran de test (800×600).
    const cible = Rect.fromLTWH(600, 400, 160, 200);
    var debuts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinchToClose(
            onClose: () {},
            onStart: () => debuts++,
            target: () => cible,
            // Une boîte SANS taille propre serait de zéro pixel sous des
            // contraintes lâches : rien ne serait touché.
            child: const SizedBox.expand(child: ColoredBox(color: Colors.red)),
          ),
        ),
      ),
    );
    final a = await tester.startGesture(const Offset(200, 200), pointer: 1);
    final b = await tester.startGesture(const Offset(600, 400), pointer: 2);
    await tester.pump();
    await a.moveTo(const Offset(250, 240));
    await b.moveTo(const Offset(550, 360));
    await tester.pump();
    expect(debuts, 1, reason: 'le dessous a été prévenu au premier mouvement');

    // La transformation appliquée : une translation vers la cible (à droite
    // et vers le bas), et une échelle < 1.
    final transform = tester.widget<Transform>(find.byType(Transform).first);
    final m = transform.transform;
    final tx = m.storage[12];
    final ty = m.storage[13];
    final sx = m.storage[0];
    expect(tx, greaterThan(0));
    expect(tx, lessThan(cible.center.dx - 400));
    expect(ty, greaterThan(0));
    expect(ty, lessThan(cible.center.dy - 300));
    expect(sx, lessThan(1));
    expect(sx, greaterThan(cible.width / 800));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
  });
}
