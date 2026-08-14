import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Vignette d'une face de card (grilles : bibliothèque, enregistrements,
/// profil).
///
/// Une face peut être une **vidéo** : la décoder comme une image lève
/// « Invalid image data » (erreur vue en boucle dans le journal de Jay,
/// 2026-07-14). On ne tente donc le décodage que pour les images, et un
/// `errorBuilder` couvre le reste (fichier corrompu, URL expirée).
///
/// À savoir : ces vignettes passent encore par le RÉSEAU — le cache local
/// n'est câblé que sur le viewer (dette connue, `RAPPELS.md`).
class FaceThumb extends StatelessWidget {
  const FaceThumb({super.key, required this.path, required this.url});

  /// Chemin de la face dans le bucket (sert à reconnaître une vidéo).
  final String path;

  /// URL signée, nulle tant qu'elle n'est pas résolue.
  final String? url;

  static bool isVideo(String path) => path.toLowerCase().endsWith('.mp4');

  @override
  Widget build(BuildContext context) {
    if (isVideo(path)) return const _Placeholder(icon: Icons.videocam);
    final resolved = url;
    if (resolved == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }
    return Image.network(
      resolved,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const _Placeholder(icon: Icons.broken_image),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    // Vignette d'habillage (listes, grilles) : elle suit le thème. L'icône
    // passe de `white38` — invisible sur fond clair — à la nuance `faint`.
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(icon, color: context.faint, size: 28)),
    );
  }
}
