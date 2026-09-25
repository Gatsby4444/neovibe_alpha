import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// **Ouvrir un média scellé tenu EN MÉMOIRE** — sans fichier, donc aussi dans
/// un navigateur (2026-09-25).
///
/// La console de modération tourne sur le web : elle n'a ni disque ni natif,
/// et [ChunkedSeal] / `MediaSeal` lisent des `File`. Elle reçoit les octets
/// scellés d'une preuve (`admin_report_evidence`) et les ouvre ici.
///
/// ⚠️ **Le même format, pas une seconde idée du format** : en-tête `NVC1`
/// (magie, taille de bloc LUE dans l'en-tête, longueur du clair), blocs de
/// taille fixe `bloc + 28` ; sinon le format hérité, un seul bloc AES-GCM.
/// `test/sealed_bytes_test.dart` ouvre ici ce que [ChunkedSeal.sealFile] et
/// `MediaSeal` ont scellé — c'est ce qui empêche les deux lectures de
/// diverger en silence.
class SealedBytes {
  SealedBytes._();

  static final _algorithm = AesGcm.with256bits();
  static const _magic = 0x4E564331; // 'NVC1'
  static const _header = 16;
  static const _overhead = 12 + 16; // nonce + MAC

  static bool isChunked(Uint8List sealed) =>
      sealed.length >= _header &&
      ByteData.sublistView(sealed).getUint32(0) == _magic;

  /// Le clair entier. [keyBase64] nul = le fichier a été déposé en clair
  /// (Vibes d'avant le chiffrement) : rendu tel quel.
  static Future<Uint8List> open(Uint8List sealed, String? keyBase64) async {
    if (keyBase64 == null) return sealed;
    final key = SecretKey(base64Decode(keyBase64));
    if (!isChunked(sealed)) {
      final clear = await _algorithm.decrypt(
        SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16),
        secretKey: key,
      );
      return Uint8List.fromList(clear);
    }
    final head = ByteData.sublistView(sealed, 0, _header);
    final taille = head.getUint32(4);
    // ⚠️ Pas de `getUint64` : il n'existe pas une fois compilé pour le web
    // (dart2js), et la console tourne dans un navigateur. Deux moitiés de
    // 32 bits disent la même chose.
    final total = head.getUint32(8) * 0x100000000 + head.getUint32(12);
    if (taille <= 0) {
      throw StateError('En-tête NVC1 incohérent : bloc = $taille');
    }
    final out = BytesBuilder(copy: false);
    var pos = _header;
    var reste = total;
    while (reste > 0) {
      final clair = reste < taille ? reste : taille;
      final fin = pos + clair + _overhead;
      if (fin > sealed.length) {
        throw StateError('Média scellé tronqué : bloc à $pos');
      }
      final bloc = await _algorithm.decrypt(
        SecretBox.fromConcatenation(
          Uint8List.sublistView(sealed, pos, fin),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
      );
      out.add(bloc);
      pos = fin;
      reste -= clair;
    }
    return out.takeBytes();
  }
}
