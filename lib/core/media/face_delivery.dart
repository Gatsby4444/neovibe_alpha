import 'dart:io';

import '../../features/cards/native_media.dart';
import '../crypto/chunked_seal.dart';

/// Prépare une face pour la **livraison**, puis la scelle.
///
/// ### Pourquoi ce passage obligé existe
///
/// Trois écrans publient des faces — Vibes, stories, publications — et chacun
/// faisait sa propre séquence. Tant qu'il n'y avait qu'à sceller, la
/// duplication était sans conséquence. Dès qu'il faut *préparer* le média
/// avant de le sceller, elle en a une : **une préparation oubliée à un seul des
/// trois endroits ne se verrait ni au diff, ni à `flutter analyze`** — juste
/// une vidéo un peu plus lente à démarrer, sur un seul écran, que personne ne
/// relierait jamais à sa cause.
///
/// Il n'y a donc qu'un chemin, et il est ici.
///
/// Objectif de Jay (2026-08-12) : première image en moins de 300 ms sur un
/// contenu préchargé, moins d'une seconde à froid — pour toutes les
/// fonctionnalités, pas seulement le feed à venir.
abstract final class FaceDelivery {
  /// Prépare [source] si c'est une vidéo, puis écrit le scellé dans [target].
  ///
  /// La préparation est **sans effet de bord observable** : elle réordonne le
  /// conteneur MP4 sans toucher aux images ni au son, et un échec laisse le
  /// fichier intact (voir `Mp4FastStart.kt`). C'est pourquoi elle n'est jamais
  /// bloquante — une vidéo mal préparée reste une vidéo lisible.
  static Future<void> seal(
    File source,
    File target,
    String key, {
    required bool isVideo,
  }) async {
    if (isVideo) await NativeMedia.fastStart(source.path);
    // Scellé PAR BLOCS et en flux : une face vidéo de 28 Mo n'est jamais montée
    // en mémoire, et se lira sans écrire de clair sur le disque.
    await ChunkedSeal.sealFile(source, target, key);
  }
}
