import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../video/sealed_video_controller.dart';
import 'chunked_seal.dart';
import 'media_seal.dart';

/// Un média prêt à l'affichage.
///
/// Une **photo** arrive en mémoire, une **vidéo** reste scellée et n'est
/// ouverte que par le lecteur natif, bloc par bloc, à mesure qu'il en a besoin.
/// Dans les deux cas, plus rien n'est écrit en clair sur le disque — ce que
/// l'ancien chemin faisait systématiquement.
class OpenedMedia {
  // Dart interdit `this._champ` sur un paramètre NOMMÉ (un nom de paramètre ne
  // peut pas être privé) : l'affectation explicite est donc la seule forme
  // possible ici, et l'analyse ne le sait pas.
  // ignore_for_file: prefer_initializing_formals
  const OpenedMedia._({
    this.photoBytes,
    this.sealedVideo,
    this.clearFile,
    this.traceId,
    this.videoUrl,
    this.videoCachePath,
    this.legacyFallback,
    File? sealed,
    String? key,
  }) : _sealed = sealed,
       _key = key;

  /// Une vidéo qu'on **ne télécharge pas** : le lecteur natif ira chercher les
  /// blocs dont il a besoin, et gardera ce qui a servi dans [cachePath].
  const OpenedMedia.streaming({
    required String url,
    required String cachePath,
    required String key,
    required String traceId,
    Future<File> Function()? legacyFallback,
  }) : this._(
         videoUrl: url,
         videoCachePath: cachePath,
         key: key,
         traceId: traceId,
         legacyFallback: legacyFallback,
       );

  /// Un fichier **déjà en clair**, sans rien à déchiffrer : un Enregistrement.
  /// Les sauvegardes sont en clair par décision de Jay — c'est ce qui les rend
  /// lisibles hors ligne et indépendantes du serveur.
  const OpenedMedia.clear(File file) : this._(clearFile: file);

  /// Photo déchiffrée, en mémoire.
  final Uint8List? photoBytes;

  /// Vidéo au format par blocs, **toujours scellée** : c'est le lecteur natif
  /// qui l'ouvrira, sur ses propres fils. Rien n'est déchiffré ici.
  final File? sealedVideo;

  /// Fichier en clair sur le disque. Deux cas seulement :
  /// - un Enregistrement, en clair par conception ;
  /// - un média scellé **avant** le format par blocs, qui n'a pas d'autre
  ///   chemin. Aucune migration n'est faite — ces contenus s'éteindront
  ///   d'eux-mêmes (24 h pour une story, et les publications se recréent).
  final File? clearFile;

  /// Rattache l'affichage à la mesure d'ouverture commencée par l'écran
  /// ([VideoOpenTrace]). Nul quand ce chemin n'est pas instrumenté.
  final String? traceId;

  /// URL signée d'une vidéo lue **en flux**, et l'endroit où son cache partiel
  /// se remplit. Non nuls ensemble.
  final String? videoUrl;
  final String? videoCachePath;

  /// Comment obtenir le clair d'un média scellé **avant** le format par blocs,
  /// que le lecteur natif ne sait pas lire (`docs/format-media-scelle.md` §4).
  final Future<File> Function()? legacyFallback;

  /// De quoi régénérer le clair à la demande — pour une sauvegarde, sans
  /// rouvrir un chemin en clair permanent.
  final File? _sealed;
  final String? _key;

  bool get isVideo => sealedVideo != null || videoUrl != null;

  /// Le lecteur à donner à une face vidéo.
  ///
  /// **C'est ici, et nulle part ailleurs, que se choisit le chemin** : média
  /// scellé par blocs ou fichier déjà en clair (Enregistrement, format
  /// hérité). Les deux faces vidéo n'ont ainsi qu'un seul lecteur à connaître —
  /// sans quoi la compatibilité se serait répandue en conditions dans chaque
  /// visionneuse, ce que cette classe existe précisément pour éviter.
  SealedVideoController videoController() {
    final sealed = sealedVideo;
    final key = _key;
    final url = videoUrl;
    if (url != null && key != null && videoCachePath != null) {
      return SealedVideoController.streaming(
        url: url,
        key: key,
        cachePath: videoCachePath!,
        legacyFallback: legacyFallback,
        traceId: traceId,
      );
    }
    if (sealed != null && key != null) {
      return SealedVideoController.sealed(
        file: sealed,
        key: key,
        traceId: traceId,
      );
    }
    return SealedVideoController.clear(clearFile!, traceId: traceId);
  }

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

  /// Libère le fichier temporaire d'un média au format hérité. Un
  /// Enregistrement, lui, n'est évidemment pas supprimé.
  ///
  /// Il n'y a plus rien d'autre à révoquer : une vidéo par blocs n'a produit ni
  /// jeton, ni URL, ni fichier — c'est tout l'intérêt de la lecture native.
  Future<void> dispose() async {
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
        // Rien n'est déchiffré ici, ni maintenant, ni sur cet isolate : le
        // lecteur natif ouvrira les blocs dont il a besoin, quand il en aura
        // besoin.
        return OpenedMedia._(
          sealedVideo: sealed,
          sealed: sealed,
          key: key,
          traceId: cacheId,
        );
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
    return OpenedMedia._(
      clearFile: target,
      sealed: sealed,
      key: key,
      traceId: cacheId,
    );
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
