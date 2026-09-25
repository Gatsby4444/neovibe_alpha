import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';
import 'package:neovibe/core/crypto/media_seal.dart';
import 'package:neovibe/core/crypto/sealed_bytes.dart';

/// La console de modération ouvre les preuves EN MÉMOIRE ([SealedBytes]),
/// l'app les scelle par fichier ([ChunkedSeal], `MediaSeal`). Deux lectures
/// d'un même format divergent en silence le jour où l'une change : ce test
/// les tient ensemble, en ouvrant ici ce que l'app a vraiment scellé.
void main() {
  Uint8List clair(int n) {
    final r = Random(42);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('sealed'));
  tearDown(() => dir.delete(recursive: true));

  for (final n in [
    0,
    1,
    ChunkedSeal.chunkSize,
    ChunkedSeal.chunkSize + 1,
    3 * ChunkedSeal.chunkSize + 17,
  ]) {
    test('format par blocs, $n octets : le même clair', () async {
      final key = await ChunkedSeal.newKey();
      final source = File('${dir.path}/c')..writeAsBytesSync(clair(n));
      final scelle = File('${dir.path}/s');
      await ChunkedSeal.sealFile(source, scelle, key);
      final octets = scelle.readAsBytesSync();
      expect(SealedBytes.isChunked(octets), isTrue);
      expect(await SealedBytes.open(octets, key), clair(n));
    });
  }

  test('format hérité (un seul bloc) : le même clair', () async {
    final key = await MediaSeal.newKey();
    final octets = await MediaSeal.sealBytes(clair(5000), key);
    expect(SealedBytes.isChunked(octets), isFalse);
    expect(await SealedBytes.open(octets, key), clair(5000));
  });

  test('sans clé : un fichier déposé en clair est rendu tel quel', () async {
    expect(await SealedBytes.open(clair(10), null), clair(10));
  });

  test('une mauvaise clé ne rend rien de lisible', () async {
    final source = File('${dir.path}/c')..writeAsBytesSync(clair(100));
    final scelle = File('${dir.path}/s');
    await ChunkedSeal.sealFile(source, scelle, await ChunkedSeal.newKey());
    expect(
      () => SealedBytes.open(
        scelle.readAsBytesSync(),
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      ),
      throwsA(anything),
    );
  });
}
