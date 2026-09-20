import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/draft_store.dart';
import '../../../core/location/anchor.dart';
import '../../../core/models/library_item.dart';
import 'album_draft.dart';
import 'album_draft_codec.dart';
import 'album_draft_keeper.dart';
import 'album_editor_screen.dart';
import 'gallery/gallery_import.dart';
import 'gallery/gallery_screen.dart';

/// Les trois étapes d'une publication d'album, enchaînées : **choisir**
/// (`GalleryScreen`, notre galerie) → **éditer** (`AlbumEditorScreen`, qui
/// pousse lui-même l'écran de légende, dépose à la file native à « Suivant »
/// et libère à « Publier ») → **publier** (`PublishService`, natif, avec ou
/// sans l'app).
///
/// Rend la main dès que « Publier » est pressé : la grille du profil montre
/// la publication avec son avancement.
abstract final class AlbumFlow {
  /// [flow] : la troisième porte (Jay, 2026-09-18) — **une** vidéo, en
  /// **9:16**, jusqu'à **trois minutes**. Même galerie (les vidéos seules),
  /// même éditeur (sans le choix du format), même envoi.
  static Future<void> start(BuildContext context, {bool flow = false}) async {
    final places = flow ? 1 : kAlbumMaxMedia;
    final maxVideoMs = flow ? kFlowMaxVideoMs : kAlbumMaxVideoMs;
    // Où on est, relevé dès maintenant et sans attendre : l'éditeur le
    // recevra quand il arrivera (l'ancre, gommée — voir ContentAnchor).
    final anchor = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(anchorSourceProvider).current();
    final pick = await Navigator.of(context).push<GalleryPick>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            GalleryScreen(max: places, videosOnly: flow, allowCamera: !flow),
      ),
    );
    if (pick == null || !context.mounted) return;
    final picked = pick.file != null
        ? await GalleryImport.fromFiles(
            context,
            [pick.file!],
            freeSlots: places,
            maxVideoMs: maxVideoMs,
          )
        : await GalleryImport.toDraftMedia(
            context,
            pick.entries,
            freeSlots: places,
            maxVideoMs: maxVideoMs,
          );
    if (picked.isEmpty || !context.mounted) return;
    // **Le brouillon existe dès ici** (Brouillons, 2026-09-20) : les
    // fichiers importés sont déplacés dans son dossier avant que l'éditeur
    // ne les décode, et chaque retouche l'écrira.
    final container = ProviderScope.containerOf(context, listen: false);
    final keeper = AlbumDraftKeeper(container.read(draftStoreProvider));
    final adopted = await keeper.adoptMedia(picked);
    if (!context.mounted) return;
    await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        fullscreenDialog: true,
        // Le premier média propose le format de toute la publication
        // (règle d'Instagram) ; l'outil Format le change ensuite. Un Flow,
        // lui, est en 9:16 et n'en change pas.
        builder: (_) => AlbumEditorScreen(
          draft: flow
              ? const AlbumDraft(
                  aspect: AlbumAspect.reel,
                  flow: true,
                ).add(adopted)
              : AlbumDraft(
                  aspect: AlbumDraft.aspectFor(adopted.first),
                ).add(adopted),
          keeper: keeper,
          anchor: anchor,
        ),
      ),
    );
  }

  /// **Reprendre un brouillon** là où il a été laissé : l'éditeur, et la
  /// légende tout de suite si c'est là qu'on en était.
  static Future<void> resume(BuildContext context, Draft draft) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final keeper = AlbumDraftKeeper(
      container.read(draftStoreProvider),
      id: draft.id,
    );
    final album = AlbumDraftCodec.fromJson(draft.payload);
    await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AlbumEditorScreen(
          draft: album,
          keeper: keeper,
          openCaption: draft.step == 'caption',
        ),
      ),
    );
  }
}
