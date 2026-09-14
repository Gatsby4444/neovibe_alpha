import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/core/models/library_item.dart';

/// Depuis le 2026-09-15 une publication porte ses médias en LISTE
/// (`library_media`) : une Card y a ses faces aux places 0 et 1, un album ses
/// 1 à 11 médias. Ces tests fixent ce que `fromJson` lit — et ce que les
/// écrans Card continuent de lire par les lectures dérivées.
Map<String, dynamic> row({
  String kind = 'card',
  int? aw,
  int? ah,
  List<Map<String, dynamic>> media = const [],
}) => {
  'id': 'c1',
  'owner_id': 'u1',
  'kind': kind,
  'card_type': 'standard',
  'aspect_w': aw,
  'aspect_h': ah,
  'caption': null,
  'is_public': false,
  'encrypted': true,
  'created_at': '2026-09-15T10:00:00Z',
  'contents': {'shareable': true, 'saveable': false},
  'library_media': media,
};

void main() {
  test('une Card : recto et verso sont les places 0 et 1', () {
    final item = LibraryItem.fromJson(
      row(
        media: [
          // Volontairement dans le désordre : c'est la place qui compte,
          // pas l'ordre de la réponse.
          {'slot': 1, 'path': 'u1/c1_1.mp4', 'is_video': true},
          {'slot': 0, 'path': 'u1/c1_0.jpg', 'is_video': false},
        ],
      ),
    );
    expect(item.kind, LibraryKind.card);
    expect(item.isAlbum, isFalse);
    expect(item.frontPath, 'u1/c1_0.jpg');
    expect(item.backPath, 'u1/c1_1.mp4');
    expect(item.frontIsVideo, isFalse);
    expect(item.backIsVideo, isTrue);
    expect(item.hasBack, isTrue);
    expect(item.cardType, CardType.standard);
    expect(item.shareable, isTrue);
    expect(item.aspect, isNull);
  });

  test('une Card à face unique n\'a pas de verso', () {
    final item = LibraryItem.fromJson(
      row(
        media: [
          {'slot': 0, 'path': 'u1/c1_0.jpg', 'is_video': false},
        ],
      ),
    );
    expect(item.hasBack, isFalse);
    expect(item.backPath, isNull);
    expect(item.backIsVideo, isFalse);
  });

  test('un album : ratio, médias triés, couverture et durée', () {
    final item = LibraryItem.fromJson(
      row(
        kind: 'album',
        aw: 4,
        ah: 5,
        media: [
          {'slot': 2, 'path': 'u1/c1_2.jpg', 'is_video': false},
          {
            'slot': 0,
            'path': 'u1/c1_0.mp4',
            'is_video': true,
            'duration_ms': 42000,
            'poster_path': 'u1/c1_0_poster.jpg',
            'width': 1080,
            'height': 1350,
          },
          {'slot': 1, 'path': 'u1/c1_1.jpg', 'is_video': false},
        ],
      ),
    );
    expect(item.isAlbum, isTrue);
    expect(item.aspect, AlbumAspect.portrait);
    expect(item.media.map((m) => m.slot), [0, 1, 2]);
    expect(item.media.first.posterPath, 'u1/c1_0_poster.jpg');
    expect(item.media.first.durationMs, 42000);
    // Les lectures Card restent cohérentes même sur un album (la place 0).
    expect(item.frontPath, 'u1/c1_0.mp4');
  });

  test('un ratio inconnu ne devient pas un ratio', () {
    expect(AlbumAspect.fromDb(3, 2), isNull);
    expect(AlbumAspect.fromDb(191, 100), AlbumAspect.landscape);
    expect(AlbumAspect.landscape.ratio, closeTo(1.91, 0.001));
  });

  test('égalité de valeur : la même publication rechargée est égale', () {
    final a = LibraryItem.fromJson(
      row(
        media: [
          {'slot': 0, 'path': 'p', 'is_video': false},
        ],
      ),
    );
    final b = LibraryItem.fromJson(
      row(
        media: [
          {'slot': 0, 'path': 'p', 'is_video': false},
        ],
      ),
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    final c = LibraryItem.fromJson(
      row(
        media: [
          {'slot': 0, 'path': 'q', 'is_video': false},
        ],
      ),
    );
    expect(a, isNot(c));
  });
}
