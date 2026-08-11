import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';

/// Le format par blocs est la pièce la plus arithmétique de l'app : positions
/// calculées, dernier bloc partiel, intervalles rognés. Une erreur d'un octet
/// y est invisible à la relecture et catastrophique à l'usage.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chunked');
  });
  tearDown(() async => dir.delete(recursive: true));

  Future<File> makeFile(String name, int size) async {
    final rnd = Random(42);
    final bytes = Uint8List.fromList(
      List.generate(size, (_) => rnd.nextInt(256)),
    );
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  // Les tailles qui cassent les découpages naïfs : vide, minuscule, pile un
  // bloc, un bloc + 1, plusieurs blocs avec reste.
  const cs = ChunkedSeal.chunkSize;
  for (final size in [0, 1, 1000, cs - 1, cs, cs + 1, cs * 3 + 12345]) {
    test('aller-retour intégral — $size octets', () async {
      final key = await ChunkedSeal.newKey();
      final src = await makeFile('src_$size', size);
      final sealed = File('${dir.path}/sealed_$size');
      await ChunkedSeal.sealFile(src, sealed, key);

      expect(await ChunkedSeal.isChunked(sealed), isTrue);
      expect(await ChunkedSeal.plainLength(sealed), size);
      expect(
        await ChunkedSeal.readAll(sealed, key),
        equals(await src.readAsBytes()),
        reason: 'le clair relu doit être identique à l\'original',
      );
    });
  }

  test('lecture par intervalles — ce dont le lecteur vidéo a besoin', () async {
    final key = await ChunkedSeal.newKey();
    const size = cs * 2 + 5000;
    final src = await makeFile('range_src', size);
    final sealed = File('${dir.path}/range_sealed');
    await ChunkedSeal.sealFile(src, sealed, key);
    final clear = await src.readAsBytes();

    Future<List<int>> range(int a, int b) async {
      final out = <int>[];
      await for (final p in ChunkedSeal.read(sealed, key, start: a, end: b)) {
        out.addAll(p);
      }
      return out;
    }

    // Un intervalle DANS un bloc, un À CHEVAL sur deux, la fin exacte, et un
    // saut au milieu — les quatre demandes que fait un lecteur qui se déplace.
    expect(await range(10, 100), equals(clear.sublist(10, 100)));
    expect(
      await range(cs - 50, cs + 50),
      equals(clear.sublist(cs - 50, cs + 50)),
      reason: 'un intervalle à cheval sur deux blocs doit être recollé',
    );
    expect(await range(size - 10, size), equals(clear.sublist(size - 10)));
    expect(await range(cs * 2, size), equals(clear.sublist(cs * 2)));
    expect(await range(100, 100), isEmpty);
  });

  test('une clé fausse ne déchiffre rien', () async {
    final key = await ChunkedSeal.newKey();
    final other = await ChunkedSeal.newKey();
    final src = await makeFile('auth_src', 5000);
    final sealed = File('${dir.path}/auth_sealed');
    await ChunkedSeal.sealFile(src, sealed, key);

    expect(
      () => ChunkedSeal.readAll(sealed, other),
      throwsA(anything),
      reason: 'AES-GCM authentifie : une mauvaise clé doit lever, pas rendre '
          'des octets faux',
    );
  });

  test('un octet modifié est détecté', () async {
    final key = await ChunkedSeal.newKey();
    final src = await makeFile('tamper_src', 5000);
    final sealed = File('${dir.path}/tamper_sealed');
    await ChunkedSeal.sealFile(src, sealed, key);

    final bytes = await sealed.readAsBytes();
    bytes[ChunkedSeal.headerSize + 40] ^= 0xFF;
    await sealed.writeAsBytes(bytes);

    expect(
      () => ChunkedSeal.readAll(sealed, key),
      throwsA(anything),
      reason: 'le MAC de GCM doit rejeter un bloc altéré',
    );
  });

  test('un fichier d\'un autre format n\'est pas pris pour du chunked', () async {
    final f = await makeFile('foreign', 200);
    expect(await ChunkedSeal.isChunked(f), isFalse);
  });
}
