import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/content/saved_store.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/gallery/gallery_screen.dart';

/// **La galerie : des Vibes datées et situées** (Jay, 2026-09-25).
void main() {
  final lundi = DateTime(2026, 9, 21, 22, 10);
  final mardi = DateTime(2026, 9, 22, 23, 40);

  SavedItem vibe(
    String id, {
    required DateTime quand,
    String? ville,
    String? lieu,
    String? soiree,
  }) => SavedItem(
    contentId: id,
    cardType: CardType.standard,
    frontPath: '/nulle/part/$id.jpg',
    savedAt: DateTime(2026, 9, 25),
    frontIsVideo: false,
    takenAt: quand,
    city: ville,
    placeName: lieu,
    eventId: soiree == null ? null : 'ev-$soiree',
    eventTitle: soiree,
  );

  group('ce qu\'une Vibe gardée dit d\'elle-même', () {
    test('date, lieu et soirée survivent à l\'écriture', () {
      final v = vibe(
        'a',
        quand: mardi,
        ville: 'Lyon',
        lieu: 'Le Sucre',
        soiree: 'Tgv',
      );
      final relue = SavedItem.fromJson('a', v.toJson());
      expect(relue.when, mardi);
      expect(relue.where, 'Le Sucre', reason: 'le lieu nommé passe avant');
      expect(relue.city, 'Lyon');
      expect(relue.fromEvent, isTrue);
      expect(relue.eventTitle, 'Tgv');
    });

    test('une sauvegarde d\'avant se relit : datée de son enregistrement', () {
      final ancienne = SavedItem.fromJson('b', {
        'cardType': 'standard',
        'frontPath': '/x.jpg',
        'savedAt': '2026-09-01T12:00:00.000',
      });
      expect(ancienne.when, DateTime(2026, 9, 1, 12));
      expect(ancienne.where, isNull);
      expect(ancienne.fromEvent, isFalse);
    });
  });

  group('l\'écran', () {
    Future<void> ouvrir(WidgetTester tester, List<SavedItem> items) async {
      // Un écran assez haut pour que tous les jours soient construits : une
      // liste ne construit pas ce qui est hors de l'écran.
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [savedItemsProvider.overrideWith((ref) async => items)],
          child: const MaterialApp(home: GalleryScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    final items = [
      vibe('a', quand: lundi, ville: 'Lyon'),
      vibe('b', quand: mardi, ville: 'Lyon', lieu: 'Le Sucre', soiree: 'Tgv'),
      vibe('c', quand: mardi.add(const Duration(minutes: 5)), ville: 'Paris'),
    ];

    testWidgets('« Tout » : les Vibes directement, rangées par jour', (
      tester,
    ) async {
      await ouvrir(tester, items);
      expect(find.text('Mardi 22 septembre'), findsOneWidget);
      expect(find.text('Lundi 21 septembre'), findsOneWidget);
      // Le lieu et la soirée sont écrits sur la Vibe.
      expect(find.text('Tgv · Le Sucre'), findsOneWidget);
      expect(find.text('Paris'), findsOneWidget);
      // Aucune porte vers un récap : pas de titre de soirée en en-tête.
      expect(find.text('Tgv'), findsNothing);
    });

    testWidgets('« Soirées » : seulement celles des événements, par soirée', (
      tester,
    ) async {
      await ouvrir(tester, items);
      await tester.tap(find.text('Soirées'));
      await tester.pumpAndSettle();
      expect(find.text('Tgv'), findsOneWidget);
      expect(find.text('Le Sucre · Mardi 22 septembre'), findsOneWidget);
      expect(find.text('Paris'), findsNothing);
      expect(find.text('Lundi 21 septembre'), findsNothing);
    });
  });
}
