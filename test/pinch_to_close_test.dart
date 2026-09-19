import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/pinch_to_close.dart';

/// **Pincer ne remet pas l'écran à zéro.** Jusqu'au 2026-09-19, l'écran
/// n'était emballé (échelle + découpage) qu'à partir du premier pincement :
/// deux arbres différents pour Flutter, donc une reconstruction — la liste
/// des Vibes repartait à sa page de départ, le lecteur d'un Flow au début.
void main() {
  testWidgets('un pincement commencé : la liste garde sa page', (tester) async {
    final c = PageController(initialPage: 0);
    var ferme = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinchToClose(
            onClose: () => ferme++,
            child: PageView(
              controller: c,
              scrollDirection: Axis.vertical,
              children: const [
                ColoredBox(color: Colors.red),
                ColoredBox(color: Colors.blue),
                ColoredBox(color: Colors.green),
              ],
            ),
          ),
        ),
      ),
    );
    // On avance de deux pages, comme en plein écran.
    c.jumpToPage(2);
    await tester.pumpAndSettle();
    expect(c.page, 2);

    // Deux doigts qui se rapprochent un peu — pas assez pour fermer.
    final a = await tester.startGesture(const Offset(200, 200), pointer: 1);
    final b = await tester.startGesture(const Offset(600, 400), pointer: 2);
    await tester.pump();
    await a.moveTo(const Offset(215, 208));
    await b.moveTo(const Offset(585, 392));
    await tester.pump();
    // Le contre-test : avec l'ancienne structure, la liste reconstruite
    // repartait à la page 0 ici.
    expect(c.page, 2);
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(c.page, 2);
    expect(ferme, 0);
    c.dispose();
  });
}
