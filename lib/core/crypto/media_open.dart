import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'chunked_seal.dart';
import 'media_seal.dart';
import 'media_stream_server.dart';

/// Un média prêt à l'affichage.
///
/// Une **photo** arrive en mémoire, une **vidéo** par une URL locale servie
/// bloc par bloc. Dans les deux cas, plus rien n'est écrit en clair sur le
/// disque — ce que l'ancien chemin faisait systématiquement.
class OpenedMedia {
  // Dart interdit `this._champ` sur un paramètre NOMMÉ (un nom de paramètre ne
  // peut pas être privé) : l'affectation explicite est donc la seule forme
  // possible ici, et l'analyse ne le sait pas.
  // ignore_for_file: prefer_initializing_formals
  const OpenedMedia._({
    this.photoBytes,
    this.videoUrl,
    this.clearFile,
    File? sealed,
    String? key,
  }) : _sealed = sealed,
       _key = key;

  /// Un fichier **déjà en clair**, sans rien à déchiffrer : un Enregistrement.
  /// Les sauvegardes sont en clair par décision de Jay — c'est ce qui les rend
  /// lisibles hors ligne et indépendantes du serveur.
  const OpenedMedia.clear(File file) : this._(clearFile: file);

  /// Photo déchiffrée, en mémoire.
  final Uint8List? photoBytes;

  /// Vidéo servie par le serveur local, bloc par bloc.
  final Uri? videoUrl;

  /// Fichier en clair sur le disque. Deux cas seulement :
  /// - un Enregistrement, en clair par conception ;
  /// - un média scellé **avant** le format par blocs, qui n'a pas d'autre
  ///   chemin. Aucune migration n'est faite — ces contenus s'éteindront
  ///   d'eux-mêmes (24 h pour une story, et les publications se recréent).
  final File? clearFile;

  /// De quoi régénérer le clair à la demande — pour une sauvegarde, sans
  /// rouvrir un chemin en clair permanent.
  final File? _sealed;
  final String? _key;

  bool get isVideo => videoUrl != null;

  /// Écrit le clair vers [target]. Utilisé par « Enregistrer », où le fichier
  /// en clair sur l'appareil est le **but** et non un compromis.
  ///
  /// Passe par le flux quand c'est possible : une vidéo de 28 Mo n'est jamais
  /// montée en mémoire.
  Future<void> writeClearTo(File target) async {
    final bytes = photoBytes;
    if (bytes != null) {
      await target.writeAsBytes(bytes, flush: true);
      return;
    }
    final sealed = _sealed;
    final key = _key;
    if (sealed != null && key != null) {
      await MediaOpen.writeClear(sealed, key, target);
      return;
    }
    final file = clearFile;
    if (file != null) await file.copy(target.path);
  }

  /// Libère ce qui doit l'être : le jeton du serveur local, et le fichier
  /// temporaire d'un média au format hérité. Un Enregistrement, lui, n'est
  /// évidemment pas supprimé.
  Future<void> dispose() async {
    final url = videoUrl;
    if (url != null) MediaStreamServer.instance.revoke(url);
    // On ne supprime que ce qu'on a fabriqué : le clair hérité vit dans le
    // répertoire temporaire, un Enregistrement non.
    final file = clearFile;
    if (file != null && _sealed != null) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

/// Ouvre un média scellé, quel que soit son format.
///
/// C'est **le seul endroit** de l'app qui sait qu'il existe deux formats. Les
/// écrans ne voient qu'un [OpenedMedia] — sans quoi la compatibilité se serait
/// répandue en conditions dans chaque visionneuse.
class MediaOpen {
  MediaOpen._();

  static Future<OpenedMedia> open(
    File sealed,
    String key, {
    required bool isVideo,
    required String cacheId,
  }) async {
    if (await ChunkedSeal.isChunked(sealed)) {
      if (isVideo) {
        // Rien n'est déchiffré ici : le serveur le fera bloc par bloc, à la
        // demande du lecteur.
        final url = await MediaStreamServer.instance.publish(sealed, key);
        return OpenedMedia._(videoUrl: url, sealed: sealed, key: key);
      }
      return OpenedMedia._(
        photoBytes: await ChunkedSeal.readAll(sealed, key),
        sealed: sealed,
        key: key,
      );
    }

    // ─── Format hérité (bloc unique) ───────────────────────────────────
    if (!isVideo) {
      // Une photo tient en mémoire : on évite le disque même ici.
      return OpenedMedia._(
        photoBytes: await MediaSeal.unsealBytes(
          await sealed.readAsBytes(),
          key,
        ),
        sealed: sealed,
        key: key,
      );
    }
    final temp = await getTemporaryDirectory();
    final target = File('${temp.path}/legacy_clear_$cacheId.mp4');
    await MediaSeal.unsealToFile(sealed, key, target);
    return OpenedMedia._(clearFile: target, sealed: sealed, key: key);
  }

  /// Écrit le clair de bout en bout, en flux.
  static Future<void> writeClear(File sealed, String key, File target) async {
    if (await ChunkedSeal.isChunked(sealed)) {
      final out = target.openWrite();
      try {
        await for (final part in ChunkedSeal.read(sealed, key)) {
          out.add(part);
        }
      } finally {
        await out.close();
      }
      return;
    }
    await MediaSeal.unsealToFile(sealed, key, target);
  }
}
