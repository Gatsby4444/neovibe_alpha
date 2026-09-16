import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/anchored_list.dart';

/// Des hauteurs franchement différentes, comme dans le fil : une Vibe, un
/// album, une légende longue. Rien ici ne doit être calculable d'avance.
double _hauteur(int i) => 120.0 + (i % 5) * 137.0;

Widget _liste({required int count, required int anchor}) => MaterialApp(
  home: Scaffold(
    body: AnchoredList(
      itemCount: count,
      anchorIndex: anchor,
      itemBuilder: (context, i) =>
          SizedBox(key: ValueKey('item$i'), height: _hauteur(i)),
    ),
  ),
);

void main() {
  testWidgets('la liste s\'ouvre pile sur l\'ancre, très loin dans la liste', (
    tester,
  ) async {
    await tester.pumpWidget(_liste(count: 60, anchor: 42));
    await tester.pump();

    final fenetre = tester.getTopLeft(find.byType(AnchoredList)).dy;
    final ancre = tester.getTopLeft(find.byKey(const ValueKey('item42'))).dy;
    // Pile en haut : pas « à peu près », pas « à un cacheExtent près ».
    expect(ancre, fenetre);

    // Et il y a bien 42 éléments au-dessus — dont aucun n'a eu besoin d'être
    // mesuré : ils ne sont même pas construits.
    expect(find.byKey(const ValueKey('item0')), findsNothing);
    expect(find.byKey(const ValueKey('item41')), findsNothing);
  });

  testWidgets('remonter révèle les précédents, dans l\'ordre', (tester) async {
    await tester.pumpWidget(_liste(count: 60, anchor: 42));
    await tester.pump();

    await tester.drag(find.byType(AnchoredList), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('item41')), findsOneWidget);
    final avant = tester.getTopLeft(find.byKey(const ValueKey('item41'))).dy;
    final ancre = tester.getTopLeft(find.byKey(const ValueKey('item42'))).dy;
    expect(avant, lessThan(ancre));
    // Collés : le précédent finit là où l'ancre commence.
    expect(avant + _hauteur(41), moreOrLessEquals(ancre, epsilon: 0.5));
  });

  testWidgets('ancre 0 : la liste part du début, comme une liste ordinaire', (
    tester,
  ) async {
    await tester.pumpWidget(_liste(count: 60, anchor: 0));
    await tester.pump();

    final fenetre = tester.getTopLeft(find.byType(AnchoredList)).dy;
    expect(tester.getTopLeft(find.byKey(const ValueKey('item0'))).dy, fenetre);
  });

  testWidgets('une ancre hors bornes se recale au lieu de casser', (
    tester,
  ) async {
    await tester.pumpWidget(_liste(count: 3, anchor: 9));
    await tester.pump();

    final fenetre = tester.getTopLeft(find.byType(AnchoredList)).dy;
    expect(tester.getTopLeft(find.byKey(const ValueKey('item2'))).dy, fenetre);
  });
}
