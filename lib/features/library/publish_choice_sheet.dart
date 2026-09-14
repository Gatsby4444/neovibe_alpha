import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../cards/card_capture_screen.dart';
import '../../core/motion.dart';
import 'album_editor/album_flow.dart';

/// Le choix qui s'ouvre sur « Publier » depuis le profil (Jay, 2026-09-15) :
///
/// - **Une Vibe** — notre caméra, restreinte à la publication (pas de story,
///   pas d'amis : la destination est imposée) ;
/// - **Photos ou vidéos** — l'éditeur d'album : jusqu'à 11 médias feuilletés.
///
/// *« On construit un système hybride en promouvant le plus notre format Card
/// mais en gardant la possibilité de publier du contenu vertical. »* La Vibe
/// vient donc en premier.
Future<void> showPublishChoice(BuildContext context) async {
  final choix = await showModalBottomSheet<_Choix>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'Publier dans ma bibliothèque',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.style_outlined),
            title: const Text('Une Vibe'),
            subtitle: Text(
              'Avec la caméra NeoVibe — une ou deux faces',
              style: TextStyle(color: context.muted),
            ),
            onTap: () => Navigator.pop(context, _Choix.vibe),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photos ou vidéos'),
            subtitle: Text(
              'Jusqu\'à 11, depuis la galerie ou l\'appareil photo',
              style: TextStyle(color: context.muted),
            ),
            onTap: () => Navigator.pop(context, _Choix.album),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choix == null || !context.mounted) return;
  switch (choix) {
    case _Choix.vibe:
      await Navigator.of(context).push(
        NeoFadeRoute(
          builder: (_) => const CardCaptureScreen(publicationOnly: true),
        ),
      );
    case _Choix.album:
      await AlbumFlow.start(context);
  }
}

enum _Choix { vibe, album }
