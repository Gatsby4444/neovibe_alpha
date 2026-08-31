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
  ///
  /// ⚠️ **Cette constante ne vaut QUE pour l'écriture.** À la lecture, la
  /// taille de bloc se lit dans l'en-tête du fichier ouvert ([_entete]) : c'est
  /// ce qui permet de changer cette valeur sans rendre illisibles les médias
  /// déjà scellés. La modifier reste donc sans danger — ce qui n'était pas vrai
  /// avant le 2026-08-31.
  static const chunkSize = 256 * 1024;

  static const _overhead = 12 + 16; // nonce + MAC
  // ⚠️ **`_sealedChunk` a été RETIRÉ le 2026-08-31.** Il valait
  // `chunkSize + _overhead` et servait à naviguer dans un fichier existant —
  // c'est-à-dire à supposer, à la LECTURE, la taille de bloc de la version
  // courante. La taille se lit désormais dans l'en-tête du fichier lu (voir
  // [_entete]), et le pas se calcule à partir d'elle.
  //
  // Le garder aurait laissé, à côté du chemin juste, une constante qui
  // ressemble à la bonne réponse et n'en est plus une.
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
          final clear = await _lireExactement(input, take);
          if (clear.length != take) {
            // La source a rétréci sous nos pieds, ou la lecture s'est arrêtée
            // court. Écrire quand même produirait un fichier dont tous les
            // blocs suivants seraient décalés — illisible, et sans erreur.
            throw StateError(
              'Source tronquée pendant le scellage : ${clear.length} octets '
              'lus au lieu de $take',
            );
          }
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

  /// L'en-tête d'un média scellé : la taille d'un bloc **telle qu'elle y est
  /// écrite**, et la longueur du clair d'origine.
  ///
  /// ## 🔴 Pourquoi la taille de bloc se LIT — corrigé le 2026-08-31
  ///
  /// Le format écrit cette taille dans son en-tête précisément pour être
  /// auto-descriptif. La moitié Kotlin la lit, et le commente : *« Lue dans
  /// l'en-tête, jamais supposée. »* **Cette moitié-ci utilisait la constante
  /// compilée** et ignorait le champ.
  ///
  /// Sans conséquence aujourd'hui — les deux valent 256 Ko. Mais le jour où
  /// [chunkSize] change, le natif continue de lire correctement les médias
  /// d'avant et le Dart cesse de le faire, **en silence**, par un échec
  /// d'authentification incompréhensible. Les deux moitiés d'un même format ne
  /// peuvent pas avoir deux niveaux de tolérance : c'est la plus stricte qui
  /// décide, et personne ne sait laquelle c'est.
  static Future<({int chunkSize, int plainLength})> _entete(File sealed) async {
    // On collecte le flux au lieu de prendre son premier morceau : rien ne
    // garantit qu'une lecture de 16 octets arrive en un seul événement.
    final head = await sealed
        .openRead(0, headerSize)
        .fold<List<int>>([], (acc, part) => acc..addAll(part));
    if (head.length < headerSize) {
      throw StateError('En-tête NVC1 tronqué : ${head.length} octets');
    }
    final data = ByteData.sublistView(Uint8List.fromList(head));
    final taille = data.getUint32(4);
    if (taille <= 0) {
      throw StateError('En-tête NVC1 incohérent : bloc = $taille');
    }
    return (chunkSize: taille, plainLength: data.getUint64(8));
  }

  /// Longueur du clair, lue dans l'en-tête. Le lecteur vidéo en a besoin
  /// **avant** de demander le moindre octet.
  static Future<int> plainLength(File sealed) async =>
      (await _entete(sealed)).plainLength;

  /// Lit exactement [combien] octets, ou moins seulement en fin de fichier.
  ///
  /// ⚠️ **`RandomAccessFile.read` peut rendre MOINS que demandé.** Le scellage
  /// supposait le contraire (`remaining -= take` après un unique `read`) : une
  /// lecture courte aurait produit un bloc plus petit que la taille annoncée,
  /// et **tous les blocs suivants auraient été décalés** — un format à pas fixe
  /// n'a pas d'index pour s'en apercevoir. Le fichier aurait été illisible sans
  /// que rien, à l'écriture, ne le signale.
  static Future<List<int>> _lireExactement(
    RandomAccessFile input,
    int combien,
  ) async {
    final out = BytesBuilder(copy: false);
    while (out.length < combien) {
      final part = await input.read(combien - out.length);
      if (part.isEmpty) break; // fin de fichier
      out.add(part);
    }
    return out.takeBytes();
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
    // ⚠️ **Taille de bloc et longueur du clair viennent TOUTES DEUX de
    // l'en-tête** (2026-08-31). Mélanger une valeur lue et une valeur compilée,
    // c'est décrire deux fichiers différents avec la même arithmétique.
    final entete = await _entete(sealed);
    final taille = entete.chunkSize;
    final scelleParBloc = taille + _overhead;
    final total = entete.plainLength;
    final last = (end ?? total).clamp(0, total);
    if (start >= last) return;

    final firstChunk = start ~/ taille;
    final lastChunk = (last - 1) ~/ taille;

    final input = await sealed.open();
    try {
      for (var i = firstChunk; i <= lastChunk; i++) {
        // La position se CALCULE : taille scellée fixe, pas de table d'index.
        await input.setPosition(headerSize + i * scelleParBloc);

        // Taille du clair dans CE bloc : pleine, sauf le dernier.
        final chunkStart = i * taille;
        final plainInChunk = (total - chunkStart).clamp(0, taille);
        if (plainInChunk <= 0) break;

        final sealedBytes = await _lireExactement(
          input,
          plainInChunk + _overhead,
        );
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
