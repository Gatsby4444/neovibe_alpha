import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/library_item.dart';
import 'package:neovibe/features/library/library_repository.dart';

AlbumMediaUpload photo() =>
    AlbumMediaUpload(File('/tmp/p.jpg'), isVideo: false);

AlbumMediaUpload video() => AlbumMediaUpload(
  File('/tmp/v.mp4'),
  isVideo: true,
  durationMs: 4000,
  poster: File('/tmp/v.jpg'),
);

/// **Le Flow** — une vidéo publiée seule (Jay, 2026-09-17).
///
/// Ce que ce test défend : la requalification se décide **sur le contenu**,
/// au seul endroit qui le voit. Un écran qui la déciderait laisserait passer
/// tous les autres chemins de publication.
void main() {
  group('La requalification', () {
    test('une vidéo seule devient un Flow', () {
      expect(kindDuContenu([video()]), LibraryKind.flow);
    });

    test('accompagnée, c\'est une publication ordinaire', () {
      expect(kindDuContenu([video(), photo()]), LibraryKind.album);
      expect(kindDuContenu([video(), video()]), LibraryKind.album);
    });

    test('une photo seule reste une publication', () {
      expect(kindDuContenu([photo()]), LibraryKind.album);
    });
  });

  group('Ce qu\'un Flow partage, et ce qui le distingue', () {
    test('il se regarde comme une publication, pas comme une Vibe', () {
      expect(LibraryKind.flow.isPublication, isTrue);
      expect(LibraryKind.album.isPublication, isTrue);
      expect(
        LibraryKind.card.isPublication,
        isFalse,
        reason: 'une Vibe se retourne : elle ne se feuillette pas',
      );
    });

    test('la base et l\'app s\'accordent sur les trois noms', () {
      for (final k in LibraryKind.values) {
        expect(LibraryKind.fromDb(k.dbValue), k);
      }
      // Un nom inconnu (une base plus récente que l'app) retombe sur la
      // Vibe : le format le plus contraint, jamais le plus permissif.
      expect(LibraryKind.fromDb('quelque_chose'), LibraryKind.card);
    });
  });
}
