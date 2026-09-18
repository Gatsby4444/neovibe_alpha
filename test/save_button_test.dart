import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/content/saved_store.dart';
import 'package:neovibe/core/crypto/media_open.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/core/widgets/save_button.dart';

/// Un magasin dont l'écriture dure aussi longtemps qu'on le décide : c'est
/// exactement la situation d'un Flow de 36 Mo, et ce que le bouton doit
/// montrer PENDANT.
class _MagasinLent extends SavedStore {
  _MagasinLent(super.ref);
  final ecriture = Completer<void>();
  var enregistre = false;

  @override
  Future<bool> isSaved(String contentId) async => enregistre;

  @override
  Future<void> add({
    required String contentId,
    required CardType cardType,
    required Future<void> Function(File target) writeFront,
    Future<void> Function(File target)? writeBack,
    bool frontIsVideo = false,
    bool backIsVideo = false,
    String? authorName,
    bool mine = false,
  }) async {
    ref.read(savingIdsProvider.notifier).start(contentId);
    try {
      await ecriture.future;
      enregistre = true;
      ref.read(savedIndexVersionProvider.notifier).bump();
    } finally {
      ref.read(savingIdsProvider.notifier).end(contentId);
    }
  }
}

void main() {
  testWidgets('le bouton se remplit À L\'APPUI, pas à la fin de l\'écriture', (
    tester,
  ) async {
    late _MagasinLent magasin;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedStoreProvider.overrideWith((ref) => magasin = _MagasinLent(ref)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SaveButton(
              contentId: 'c1',
              cardType: CardType.standard,
              canSave: true,
              front: OpenedMedia.clear(File('inexistant.jpg')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bookmark_border));
    await tester.pump();
    // L'écriture n'a PAS fini — et le signet est déjà plein.
    expect(magasin.ecriture.isCompleted, isFalse);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    // … et le bouton est inerte le temps qu'elle finisse.
    final bouton = tester.widget<IconButton>(find.byType(IconButton));
    expect(bouton.onPressed, isNull);

    magasin.ecriture.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
  });
}
