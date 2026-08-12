// Génère les vecteurs de test croisés du format `NVC1`.
//
// Le format a désormais DEUX implémentations — Dart pour sceller, Kotlin pour
// ouvrir — et rien dans la compilation ne détecterait qu'elles divergent. Ces
// vecteurs sont le seul point de contact entre les deux : le même fichier
// scellé est rejoué par les deux côtés, qui doivent retrouver le même clair,
// octet pour octet.
//
// **À ne relancer que si le format change délibérément** (voir
// `docs/format-media-scelle.md` §6). Régénérer pour « faire passer le test »
// annule tout l'intérêt du dispositif : les deux implémentations resteraient
// fausses ensemble.
//
//   dart run tool/gen_seal_vectors.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';

const _outDir = 'android/app/src/test/resources/seal-vectors';

/// Les longueurs de clair qui font trébucher une implémentation fausse.
const _cases = <String, int>{
  'vide': 0,
  'petit': 1000,
  'bloc_exact': ChunkedSeal.chunkSize,
  'bloc_plus_un': ChunkedSeal.chunkSize + 1,
  'multi_blocs': 600000, // 2 blocs pleins + un dernier partiel
};

Future<void> main() async {
  final dir = Directory(_outDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  final temp = await Directory.systemTemp.createTemp('nvc1_vectors');
  final vectors = <Map<String, Object?>>[];

  try {
    for (final entry in _cases.entries) {
      final clear = _plain(entry.value);
      final source = File('${temp.path}/${entry.key}.bin')
        ..writeAsBytesSync(clear);
      final sealedFile = File('$_outDir/${entry.key}.nvc1');
      final key = await ChunkedSeal.newKey();
      await ChunkedSeal.sealFile(source, sealedFile, key);

      vectors.add({
        'name': entry.key,
        'file': '${entry.key}.nvc1',
        'length': clear.length,
        'key': key,
        'sha256': await _digest(clear),
        'ranges': [
          for (final range in _ranges(clear.length))
            {
              'start': range.$1,
              'end': range.$2,
              'sha256': await _digest(
                Uint8List.sublistView(clear, range.$1, range.$2),
              ),
            },
        ],
      });
      stdout.writeln(
        '${entry.key} : ${clear.length} o de clair '
        '→ ${sealedFile.lengthSync()} o scellés',
      );
    }
  } finally {
    temp.deleteSync(recursive: true);
  }

  File('$_outDir/manifest.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'chunkSize': ChunkedSeal.chunkSize, 'vectors': vectors})}\n',
  );
  stdout.writeln('\n${vectors.length} vecteurs écrits dans $_outDir');
}

/// Un clair reproductible et non compressible : un générateur à graine fixe.
/// Des octets nuls masqueraient une erreur d'alignement (tout se ressemble).
Uint8List _plain(int length) {
  final random = Random(20260812);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// Les intervalles qui comptent : les bords, et surtout ceux **à cheval sur
/// une frontière de bloc** — l'endroit exact où une implémentation fausse se
/// trahit.
List<(int, int)> _ranges(int length) {
  if (length == 0) return const [(0, 0)];
  const chunk = ChunkedSeal.chunkSize;
  final ranges = <(int, int)>{
    (0, min(64, length)), // le tout début
    (max(0, length - 64), length), // la toute fin
    (0, length), // tout
  };
  for (var boundary = chunk; boundary < length; boundary += chunk) {
    ranges
      ..add((boundary - 10, min(boundary + 10, length))) // à cheval
      ..add((boundary, min(boundary + 32, length))) // pile au début d'un bloc
      ..add((boundary - 1, boundary)); // le dernier octet du bloc précédent
  }
  final sorted = ranges.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  return sorted;
}

Future<String> _digest(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
