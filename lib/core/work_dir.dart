import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// **Le dossier de travail des exports et des envois** — sous le dossier
/// privé et PERMANENT de l'app, jamais sous le cache.
///
/// ## Pourquoi (2026-09-19)
///
/// Le rendu d'une vidéo (20 secondes de transcodage) écrivait dans le
/// dossier **cache** de l'app. Or Android — et MIUI plus que les autres — a
/// le droit de **vider ce dossier à tout moment** quand la place ou la
/// mémoire manque. Chez Jay, téléphone à 1 % de batterie, mémoire au plus
/// bas : la troisième vidéo d'une publication a vu son fichier `.part`
/// **disparaître pendant qu'on l'écrivait** (« le rendu a disparu :
/// NoSuchFileException · tmp existe=false · dossier existe=true »), les deux
/// premières étant passées. Le cache est pour ce qui *peut* disparaître ; un
/// rendu en cours, un scellé en attente d'envoi, une copie de la galerie en
/// cours de montage, non.
///
/// Ici, c'est **nous** qui nettoyons : [sweep] au démarrage de l'app (rien
/// n'est en vol à ce moment-là), et chaque pipeline efface ce qu'il a créé.
abstract final class WorkDir {
  static Future<Directory> root() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}work');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Un sous-dossier stable (`gallery`, `seal`, `vibe_edit`…).
  static Future<Directory> named(String name) async {
    final dir = Directory(
      '${(await root()).path}${Platform.pathSeparator}$name',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Un dossier neuf pour un travail (une publication), à effacer par lui.
  static Future<Directory> fresh(String prefix) async {
    final dir = Directory(
      '${(await root()).path}${Platform.pathSeparator}'
      '${prefix}_${DateTime.now().millisecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// Au démarrage : tout ce qui reste est le reste d'un travail interrompu.
  static Future<void> sweep() async {
    try {
      final dir = await root();
      await for (final entity in dir.list()) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
