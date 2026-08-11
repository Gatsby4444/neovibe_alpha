import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Chiffrement **par blocs** — le format des médias depuis le 2026-08-12.
///
/// ### Pourquoi remplacer le bloc unique
///
/// L'ancien format scellait le fichier **entier** en une seule opération
/// AES-GCM. Pour afficher une vidéo il fallait donc la télécharger en entier,
/// la charger en mémoire, la déchiffrer en mémoire, puis **écrire le clair sur
/// le disque**. Trois défauts :
///
/// - on attend le dernier octet avant de voir la première image ;
/// - une vidéo de 28 Mo occupe ~56 Mo de mémoire (scellé + clair) ;
/// - le clair vit sur le disque pendant tout le visionnage — le seul endroit
///   de l'app où les octets ne sont pas inertes.
///
/// ### Le format
///
/// ```
///   en-tête (16 octets)
///     0..3   magie 'NVC1'
///     4..7   taille d'un bloc en clair (uint32, gros-boutiste)
///     8..15  longueur du clair d'origine (uint64)
///   puis N blocs scellés, de taille FIXE (bloc + 28), sauf le dernier
/// ```
///
/// **La propriété qui rend tout simple** : AES-GCM ajoute exactement 28 octets
/// (12 de nonce + 16 de MAC). La taille scellée d'un bloc est donc connue
/// d'avance, et la position du bloc *i* se **calcule** — aucune table d'index à
/// stocker, à maintenir ou à corrompre.
///
/// Chaque bloc a son propre nonce, tiré aléatoirement : réutiliser un nonce
/// avec la même clé casserait GCM, et c'est précisément ce qu'un découpage naïf
/// aurait pu introduire.
class ChunkedSeal {
  ChunkedSeal._();

  static final _algorithm = AesGcm.with256bits();

  /// 256 Ko : assez gros pour que le surcoût de 28 octets soit négligeable
  /// (0,01 %), assez petit pour que la lecture d'un bloc reste instantanée et
  /// la mémoire bornée.
  static const chunkSize = 256 * 1024;

  static const _overhead = 12 + 16; // nonce + MAC
  static const _sealedChunk = chunkSize + _overhead;
  static const headerSize = 16;
  static const _magic = 0x4E564331; // 'NVC1'

  static Future<String> newKey() async {
    final key = await _algorithm.newSecretKey();
    return base64Encode(await key.extractBytes());
  }

  /// Le fichier commence-t-il par la magie du format par blocs ?
  ///
  /// C'est ce qui permet aux médias scellés **avant** ce changement de rester
  /// lisibles : on ne migre rien, on reconnaît.
  static Future<bool> isChunked(File sealed) async {
    try {
      if (await sealed.length() < headerSize) return false;
      final head = await sealed.openRead(0, 4).first;
      return ByteData.sublistView(Uint8List.fromList(head)).getUint32(0) ==
          _magic;
    } catch (_) {
      return false;
    }
  }

  /// Scelle [source] vers [target], **sans jamais charger le fichier entier**.
  ///
  /// C'est déjà un gain à l'écriture : publier une vidéo de 28 Mo ne monte plus
  /// 28 Mo en mémoire, mais 256 Ko à la fois.
  static Future<void> sealFile(
    File source,
    File target,
    String keyBase64,
  ) async {
    final key = SecretKey(base64Decode(keyBase64));
    final plainLength = await source.length();

    final out = target.openWrite();
    try {
      final header = ByteData(headerSize)
        ..setUint32(0, _magic)
        ..setUint32(4, chunkSize)
        ..setUint64(8, plainLength);
      out.add(header.buffer.asUint8List());

      final input = await source.open();
      try {
        var remaining = plainLength;
        while (remaining > 0) {
          final take = remaining < chunkSize ? remaining : chunkSize;
          final clear = await input.read(take);
          final box = await _algorithm.encrypt(clear, secretKey: key);
          out.add(box.concatenation());
          remaining -= take;
        }
      } finally {
        await input.close();
      }
    } finally {
      await out.close();
    }
  }

  /// Longueur du clair, lue dans l'en-tête. Le lecteur vidéo en a besoin
  /// **avant** de demander le moindre octet.
  static Future<int> plainLength(File sealed) async {
    final head = await sealed.openRead(0, headerSize).first;
    return ByteData.sublistView(Uint8List.fromList(head)).getUint64(8);
  }

  /// Déchiffre l'intervalle de clair `[start, end)` — et **rien d'autre**.
  ///
  /// Seuls les blocs qui recouvrent l'intervalle sont lus et déchiffrés. C'est
  /// ce qui permet à un lecteur vidéo de sauter dans le fichier sans tout
  /// déchiffrer, et à la mémoire de rester bornée.
  static Stream<List<int>> read(
    File sealed,
    String keyBase64, {
    int start = 0,
    int? end,
  }) async* {
    final key = SecretKey(base64Decode(keyBase64));
    final total = await plainLength(sealed);
    final last = (end ?? total).clamp(0, total);
    if (start >= last) return;

    final firstChunk = start ~/ chunkSize;
    final lastChunk = (last - 1) ~/ chunkSize;

    final input = await sealed.open();
    try {
      for (var i = firstChunk; i <= lastChunk; i++) {
        // La position se CALCULE : taille scellée fixe, pas de table d'index.
        await input.setPosition(headerSize + i * _sealedChunk);

        // Taille du clair dans CE bloc : pleine, sauf le dernier.
        final chunkStart = i * chunkSize;
        final plainInChunk = (total - chunkStart).clamp(0, chunkSize);
        if (plainInChunk <= 0) break;

        final sealedBytes = await input.read(plainInChunk + _overhead);
        final clear = await _algorithm.decrypt(
          SecretBox.fromConcatenation(
            sealedBytes,
            nonceLength: 12,
            macLength: 16,
          ),
          secretKey: key,
        );

        // Le premier et le dernier bloc sont rognés à l'intervalle demandé.
        final from = (i == firstChunk ? start - chunkStart : 0).clamp(
          0,
          clear.length,
        );
        final to = (i == lastChunk ? last - chunkStart : clear.length).clamp(
          from,
          clear.length,
        );
        yield clear.sublist(from, to);
      }
    } finally {
      await input.close();
    }
  }

  /// Le clair en entier, en mémoire. Réservé aux **photos** : quelques
  /// centaines de kilo-octets, aucun intérêt à les servir en flux.
  static Future<Uint8List> readAll(File sealed, String keyBase64) async {
    final out = BytesBuilder(copy: false);
    await for (final part in read(sealed, keyBase64)) {
      out.add(part);
    }
    return out.takeBytes();
  }
}
