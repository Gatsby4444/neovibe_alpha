import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';

/// Vecteurs de test **croisés** du format `NVC1`.
///
/// Le même jeu de fichiers est rejoué par l'implémentation Kotlin
/// (`SealedChunkReaderTest.kt`). C'est le seul dispositif qui empêche les deux
/// implémentations de diverger : une divergence ne se verrait ni à la
/// compilation, ni à `flutter analyze`, ni au diff — seulement à l'exécution,
/// sur l'appareil.
///
/// Les vecteurs sont **figés**. S'ils échouent, c'est le code qui a changé, pas
/// eux — voir `docs/format-media-scelle.md` §6 avant de toucher à quoi que ce
/// soit.
void main() {
  final dir = Directory('android/app/src/test/resources/seal-vectors');
  final manifest =
      jsonDecode(File('${dir.path}/manifest.json').readAsStringSync())
          as Map<String, dynamic>;

  test('la taille de bloc du manifeste est celle du code', () {
    expect(manifest['chunkSize'], ChunkedSeal.chunkSize);
  });

  for (final entry
      in (manifest['vectors'] as List).cast<Map<String, dynamic>>()) {
    final name = entry['name'] as String;
    final sealed = File('${dir.path}/${entry['file']}');
    final key = entry['key'] as String;

    group('vecteur « $name »', () {
      test('reconnu comme format par blocs', () async {
        expect(await ChunkedSeal.isChunked(sealed), isTrue);
      });

      test('longueur du clair annoncée dans l\'en-tête', () async {
        expect(await ChunkedSeal.plainLength(sealed), entry['length']);
      });

      test('clair entier conforme à l\'empreinte', () async {
        expect(
          await _digest(await ChunkedSeal.readAll(sealed, key)),
          entry['sha256'],
        );
      });

      for (final range
          in (entry['ranges'] as List).cast<Map<String, dynamic>>()) {
        final start = range['start'] as int;
        final end = range['end'] as int;
        test('intervalle [$start, $end)', () async {
          final bytes = <int>[];
          await for (final part in ChunkedSeal.read(
            sealed,
            key,
            start: start,
            end: end,
          )) {
            bytes.addAll(part);
          }
          expect(bytes.length, end - start);
          expect(await _digest(bytes), range['sha256']);
        });
      }
    });
  }
}

Future<String> _digest(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
