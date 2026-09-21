import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/content/content_face.dart';
import 'package:neovibe/core/models/library_item.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/library/mini_card.dart';

/// **Une zone neutre sous chaque mini** (Jay, 2026-09-18) : balayer une
/// vignette sans verso ne doit jamais remonter au balayage de l'écran, qui
/// change de section. Le détecteur du dessous joue ici le rôle de
/// `HomeShell`.
void main() {
  LibraryItem item() => LibraryItem(
    id: 'p1',
    ownerId: 'moi',
    media: const [LibraryMedia(slot: 0, path: 'moi/p1_0.jpg')],
    createdAt: DateTime(2026, 9, 18),
  );

  Future<int> balayages(WidgetTester tester, LibraryItem item) async {
    var compte = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('moi'),
          // Une face « ouverte » sans image valable : la vignette montre son
          // repli. Ce qui compte ici, c'est le geste, pas les pixels.
          contentFaceProvider.overrideWith(
            (ref, spec) async => throw StateError('pas de média en test'),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              onHorizontalDragUpdate: (_) => compte++,
              child: Center(
                child: SizedBox(
                  width: 120,
                  child: MiniCard(item: item, onTap: () {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(MiniCard), const Offset(80, 0));
    await tester.pumpAndSettle();
    return compte;
  }

  testWidgets('balayer une face unique ne remonte pas à l\'écran', (
    tester,
  ) async {
    expect(await balayages(tester, item()), 0);
  });

  testWidgets('le contre-test : à côté de la mini, l\'écran balaie', (
    tester,
  ) async {
    var compte = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (_) => compte++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(GestureDetector), const Offset(80, 0));
    expect(compte, greaterThan(0));
  });
}
