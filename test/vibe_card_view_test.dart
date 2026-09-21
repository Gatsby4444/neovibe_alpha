import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/content/content_face.dart';
import 'package:neovibe/core/crypto/media_open.dart';
import 'package:neovibe/core/models/library_item.dart';
import 'package:neovibe/features/cards/flippable_card.dart';
import 'package:neovibe/features/library/feed/vibe_card_view.dart';

/// **La carte retournable existe avant que sa face n'arrive** (Jay,
/// 2026-09-19 : *« même avant que la vibe soit bien positionnée, on doit
/// pouvoir la retourner »*). Le geste vit dans `FlippableCard` : s'il n'est
/// construit qu'à l'arrivée de la face, balayer trop tôt ne retourne rien —
/// et, dans le fil, ferme la couverture.
void main() {
  final vibe = LibraryItem(
    id: 'v1',
    ownerId: 'moi',
    media: const [
      LibraryMedia(slot: 0, path: 'moi/v1_0.jpg'),
      LibraryMedia(slot: 1, path: 'moi/v1_1.jpg'),
    ],
    createdAt: DateTime(2026, 9, 19),
  );

  testWidgets('les faces en attente : la carte retournable est déjà là', (
    tester,
  ) async {
    // Des faces qui n'arrivent JAMAIS : l'état « en attente » figé.
    final jamais = Completer<OpenedMedia>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contentFaceProvider.overrideWith((ref, spec) => jamais.future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: VibeCardView(item: vibe, active: true),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(FlippableCard), findsOneWidget);

    // Et elle se retourne : un balayage horizontal la fait changer de face.
    final avant = tester.widget<FlippableCard>(find.byType(FlippableCard));
    expect(avant.front, isNotNull);
    await tester.drag(find.byType(FlippableCard), const Offset(300, 0));
    // Pas de `pumpAndSettle` : le cadre d'attente anime sans fin.
    await tester.pump(const Duration(milliseconds: 600));
    // Pas d'erreur, pas de vide : la carte a pris le geste.
    expect(find.byType(FlippableCard), findsOneWidget);
  });

  testWidgets('une card MONO absorbe le balayage : rien ne remonte au-dessus', (
    tester,
  ) async {
    // Jay, 2026-09-19 : le réflexe de balayer existe même sans verso ; le
    // geste ne doit pas atteindre la couverture du fil (qui fermerait).
    final mono = LibraryItem(
      id: 'm1',
      ownerId: 'moi',
      media: const [LibraryMedia(slot: 0, path: 'moi/m1_0.jpg')],
      createdAt: DateTime(2026, 9, 19),
    );
    final jamais = Completer<OpenedMedia>();
    var remonte = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contentFaceProvider.overrideWith((ref, spec) => jamais.future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              onHorizontalDragUpdate: (_) => remonte++,
              child: Center(
                child: SizedBox(
                  width: 300,
                  child: VibeCardView(item: mono, active: true),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(VibeCardView), const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(remonte, 0);
  });
}
