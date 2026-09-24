import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/core/models/library_vibe.dart';
import 'package:neovibe/features/library_vibes/conversation_library_screen.dart';
import 'package:neovibe/features/library_vibes/library_vibes_repository.dart';

/// 🔴 La panne du 2026-09-24 (captures de Jay) : trois Vibes différentes dans
/// le Drop, une seule image. Quand une Vibe arrivait en tête, les tuiles
/// étaient réutilisées pour les Vibes décalées, et chacune gardait l'aperçu
/// chargé à sa création. Ce test donne à UNE tuile une autre Vibe, et exige
/// que l'image suive.
class _FakeRepo extends LibraryVibesRepository {
  _FakeRepo(super.ref);

  static final bytesById = <String, Uint8List>{};

  @override
  Future<Uint8List> placeholderBytes(LibraryVibe vibe, {bool back = false}) =>
      Future.value(bytesById[vibe.id]!);

  @override
  Future<void> prefetch(LibraryVibe vibe) async {}

  @override
  Future<Uint8List?> sharpPhoto(LibraryVibe vibe) async => null;
}

/// Un PNG 1×1 valide, distinct selon [shade] (octet de couleur).
Uint8List _png(int shade) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0,
  0x3A, 0x7E, 0x9B, 0x55, 0, 0, 0, 10, 0x49, 0x44, 0x41, 0x54,
  0x78, 0x9C, 0x63, shade, 0, 0, 0, 2, 0, 1, 0xE5, 0x27, 0xDE, 0xFC, //
  0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

LibraryVibe _vibe(String id) => LibraryVibe(
  id: id,
  conversationId: 'c',
  authorId: 'a',
  revealAt: DateTime.utc(2020),
  saveableByOthers: false,
  ephemeral: false,
  placeholderPath: '$id/placeholder.png',
  sealedPath: '$id/sealed.bin',
  createdAt: DateTime.utc(2020),
  type: CardType.standard,
  frontIsVideo: false,
  backIsVideo: false,
);

void main() {
  testWidgets('une tuile à qui l\'on donne une autre Vibe montre SON image', (
    tester,
  ) async {
    _FakeRepo.bytesById
      ..['v1'] = _png(0x10)
      ..['v2'] = _png(0x80);

    Widget grid(LibraryVibe v) => ProviderScope(
      overrides: [libraryVibesRepositoryProvider.overrideWith(_FakeRepo.new)],
      child: MaterialApp(
        home: SizedBox(
          width: 90,
          height: 160,
          // Sans clé, exprès : c'est le cas où Flutter réutilise la tuile.
          child: LibraryVibeTile(vibe: v, onRefresh: () {}),
        ),
      ),
    );

    Uint8List shown() {
      final image = tester.widget<Image>(find.byType(Image));
      return (image.image as MemoryImage).bytes;
    }

    await tester.pumpWidget(grid(_vibe('v1')));
    await tester.pump();
    expect(shown(), _FakeRepo.bytesById['v1']);

    await tester.pumpWidget(grid(_vibe('v2')));
    await tester.pump();
    expect(
      shown(),
      _FakeRepo.bytesById['v2'],
      reason: 'l\'image doit suivre la Vibe, pas la case',
    );
  });
}
