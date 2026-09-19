import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/app.dart' show routeObserver;
import 'package:neovibe/core/widgets/reel_route.dart';
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
                            // La route réelle du plein écran : depuis le
                            // 2026-09-18 elle n'est PAS opaque (une
                            // superposition), et le fil doit se taire quand
                            // même.
                            onPressed: () => Navigator.of(context).push(
                              ReelRoute<void>(
                                builder: (_) => const Scaffold(
                                  backgroundColor: Colors.transparent,
                                  body: Text('plein écran'),
                                ),
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

  testWidgets('dans une section HORS HORLOGE (TickerMode coupé), le fil se '
      'tait ; remis, il reprend', (tester) async {
    // La coquille coupe l'horloge des sections cachées : c'est ce que le
    // suiveur écoute quand on change de section par la barre en laissant le
    // fil (une couverture) derrière soi.
    final enabled = ValueNotifier<bool>(true);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: enabled,
        builder: (context, on, _) => TickerMode(enabled: on, child: _fil()),
      ),
    );
    await tester.pump();
    expect(_publies.last, 'a');

    enabled.value = false;
    await tester.pump();
    expect(_publies.last, isNull);

    enabled.value = true;
    await tester.pump();
    await tester.pump();
    expect(_publies.last, 'a');
    enabled.dispose();
  });
}
