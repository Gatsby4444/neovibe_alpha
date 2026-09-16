import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'album_draft.dart';
import 'album_editor_screen.dart';
import 'gallery/gallery_import.dart';
import 'gallery/gallery_screen.dart';
import 'album_publish_queue.dart';

/// Les trois étapes d'une publication d'album, enchaînées : **choisir**
/// (`GalleryScreen`, notre galerie) → **éditer** (`AlbumEditorScreen`, qui
/// pousse lui-même l'écran de légende) → **publier** (`AlbumPublishQueue`, en
/// arrière-plan).
///
/// Rend la main dès que l'envoi est déposé : le profil affiche le bandeau.
abstract final class AlbumFlow {
  static Future<void> start(BuildContext context) async {
    final pick = await Navigator.of(context).push<GalleryPick>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const GalleryScreen(max: kAlbumMaxMedia),
      ),
    );
    if (pick == null || !context.mounted) return;
    final picked = pick.file != null
        ? await GalleryImport.fromFiles(context, [
            pick.file!,
          ], freeSlots: kAlbumMaxMedia)
        : await GalleryImport.toDraftMedia(
            context,
            pick.entries,
            freeSlots: kAlbumMaxMedia,
          );
    if (picked.isEmpty || !context.mounted) return;
    final draft = await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        fullscreenDialog: true,
        // Le premier média propose le format de toute la publication
        // (règle d'Instagram) ; l'outil Format le change ensuite.
        builder: (_) => AlbumEditorScreen(
          draft: AlbumDraft(
            aspect: AlbumDraft.aspectFor(picked.first),
          ).add(picked),
        ),
      ),
    );
    if (draft == null || !context.mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(albumPublishQueueProvider).isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Une publication est déjà en cours — attends qu\'elle finisse.',
          ),
        ),
      );
      return;
    }
    // Sans `await` : l'envoi tourne en arrière-plan, la main revient tout
    // de suite (comme l'envoi d'une Vibe).
    unawaited(
      container.read(albumPublishQueueProvider.notifier).publish(draft),
    );
  }
}
