@Tags(['bench'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';

/// Mesure du débit de déchiffrement — écrit le 2026-08-12 pour chiffrer la
/// cause du saccadement vidéo signalé par Jay, au lieu de la supposer.
///
/// ⚠️ **Ce test mesure la machine de développement (x64), pas le téléphone.**
/// Un ARM de milieu de gamme est nettement plus lent à débit égal d'AES logiciel.
/// Le chiffre obtenu ici est donc un **plafond optimiste** : ce que l'appareil
/// fait est forcément moins bon.
///
/// Le point de comparaison utile : une vidéo NeoVibe est plafonnée à
/// 3,5 Mbit/s, soit **environ 0,44 Mo/s** à soutenir en lecture continue.
void main() {
  test('débit de ChunkedSeal.read', () async {
    final dir = await Directory.systemTemp.createTemp('bench');
    try {
      const size = 24 * 1024 * 1024; // ordre de grandeur d'une vidéo de 61 s
      final rnd = Random(1);
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = rnd.nextInt(256);
      }
      final src = File('${dir.path}/src')..writeAsBytesSync(bytes);
      final sealed = File('${dir.path}/sealed');
      final key = await ChunkedSeal.newKey();

      final t0 = DateTime.now();
      await ChunkedSeal.sealFile(src, sealed, key);
      final sealMs = DateTime.now().difference(t0).inMilliseconds;

      final t1 = DateTime.now();
      var read = 0;
      await for (final part in ChunkedSeal.read(sealed, key)) {
        read += part.length;
      }
      final readMs = DateTime.now().difference(t1).inMilliseconds;

      expect(read, size);
      final mb = size / (1024 * 1024);
      // ignore: avoid_print
      print(
        '\n--- débit (machine de dev, x64) ---\n'
        'scellement : $sealMs ms  →  ${(mb / (sealMs / 1000)).toStringAsFixed(1)} Mo/s\n'
        'lecture    : $readMs ms  →  ${(mb / (readMs / 1000)).toStringAsFixed(1)} Mo/s\n'
        'à soutenir pour une vidéo 3,5 Mbit/s : 0,44 Mo/s\n',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
