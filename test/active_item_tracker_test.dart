import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/app.dart' show routeObserver;
import 'package:neovibe/features/library/feed/active_item_tracker.dart';

/// Un fil de trois éléments, et ce que le suiveur publie comme « actif ».
///
/// Le point vérifié : **un fil recouvert n'a aucun élément actif**. Avant le
/// 2026-09-18, l'élément regardé restait actif sous un plein écran — son
/// lecteur vidéo continuait de décoder, invisible, pendant que le plein écran
/// ouvrait le sien sur la même vidéo.
final _publies = <String?>[];

Widget _fil() => MaterialApp(
  navigatorObservers: [routeObserver],
  home: Builder(
    builder: (context) => Scaffold(
      body: ActiveItemTracker(
        child: Builder(
          builder: (context) {
            final tracker = ActiveItemTracker.of(context);
            return ValueListenableBuilder<String?>(
              valueListenable: tracker.active,
              builder: (context, active, _) {
                _publies.add(active);
                return ListView(
                  children: [
                    for (final id in ['a', 'b', 'c'])
                      TrackedItem(
                        id: id,
                        child: SizedBox(
                          height: 300,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    const Scaffold(body: Text('plein écran')),
                              ),
                            ),
                            child: Text('ouvrir $id'),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    ),
  ),
);

void main() {
  setUp(_publies.clear);

  testWidgets('posé, le fil a un élément actif', (tester) async {
    await tester.pumpWidget(_fil());
    await tester.pump();
    expect(_publies.last, 'a');
  });

  testWidgets('recouvert par un écran, le fil n\'a AUCUN élément actif ; '
      'découvert, il le retrouve', (tester) async {
    await tester.pumpWidget(_fil());
    await tester.pump();
    expect(_publies.last, 'a');

    await tester.tap(find.text('ouvrir a'));
    await tester.pumpAndSettle();
    expect(find.text('plein écran'), findsOneWidget);
    // Le contre-test : sans l'écoute du navigateur, `a` resterait actif ici.
    expect(_publies.last, isNull);

    Navigator.of(tester.element(find.text('plein écran'))).pop();
    await tester.pumpAndSettle();
    expect(_publies.last, 'a');
  });
}
