import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'album_draft.dart';
import 'album_editor_screen.dart';
import 'album_picker.dart';
import 'album_publish_queue.dart';

/// Les trois étapes d'une publication d'album, enchaînées : **choisir**
/// (`AlbumPicker`) → **éditer** (`AlbumEditorScreen`, qui pousse lui-même
/// l'écran de légende) → **publier** (`AlbumPublishQueue`, en arrière-plan).
///
/// Rend la main dès que l'envoi est déposé : le profil affiche le bandeau.
abstract final class AlbumFlow {
  static Future<void> start(BuildContext context) async {
    final picked = await AlbumPicker.pick(context, freeSlots: kAlbumMaxMedia);
    if (picked.isEmpty || !context.mounted) return;
    final draft = await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            AlbumEditorScreen(draft: const AlbumDraft().add(picked)),
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
