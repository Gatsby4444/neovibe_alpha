import 'package:flutter/material.dart';

import '../../../../core/typography.dart';
import '../editor_theme.dart';
import 'gallery_feed.dart';
import 'native_gallery.dart';

/// **« Sélectionner un album »** — la feuille qui s'ouvre sous le titre de la
/// galerie (Jay, 2026-09-17 : *« fais une interface plus complète et pro comme
/// sur Instagram, qui permet d'afficher les albums et filtrer par d'autres
/// critères »*).
///
/// En haut, les trois raccourcis qui ne sont pas des dossiers : **Récent**,
/// **Photos**, **Vidéos**. En dessous, les dossiers du téléphone (Camera,
/// Screenshots, WhatsApp…), celui qui a le média le plus récent en premier,
/// avec leur couverture et leur compte.
///
/// La feuille ne charge rien elle-même : elle reçoit le [GalleryFeed] pour ses
/// vignettes — les mêmes que la grille, depuis le même cache. Deux caches de
/// vignettes pour les mêmes fichiers, ce serait deux fois le travail pour le
/// même résultat.
Future<GalleryFilter?> choisirAlbum(
  BuildContext context, {
  required GalleryFeed feed,
  required GalleryFilter courant,
}) => showModalBottomSheet<GalleryFilter>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _AlbumSheet(feed: feed, courant: courant),
);

class _AlbumSheet extends StatefulWidget {
  const _AlbumSheet({required this.feed, required this.courant});

  final GalleryFeed feed;
  final GalleryFilter courant;

  @override
  State<_AlbumSheet> createState() => _AlbumSheetState();
}

class _AlbumSheetState extends State<_AlbumSheet> {
  late final Future<List<GalleryAlbum>> _albums = NativeGallery.albums();

  /// Deux rangées qui défilent à l'horizontale, comme sur les captures de
  /// Jay : l'œil voit d'un coup six dossiers et devine qu'il y en a d'autres.
  /// « Voir tout » déplie la grille entière pour qui les cherche.
  var _tout = false;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // L'en-tête : « Annuler » à gauche, le titre au centre.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.sm,
              0,
              NeoSpace.sm,
              NeoSpace.sm,
            ),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler'),
                ),
                Expanded(
                  child: Text(
                    'Sélectionner un album',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: NeoType.display,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      color: c.ink,
                    ),
                  ),
                ),
                // La même largeur qu'« Annuler », pour que le titre soit
                // vraiment au milieu et non « au milieu de ce qui reste ».
                const SizedBox(width: 72),
              ],
            ),
          ),
          Row(
            children: [
              for (final f in const [
                GalleryFilter.tout,
                GalleryFilter.photos,
                GalleryFilter.videos,
              ])
                Expanded(
                  child: _Raccourci(
                    filtre: f,
                    choisi: f == widget.courant,
                    onTap: () => Navigator.pop(context, f),
                  ),
                ),
            ],
          ),
          const SizedBox(height: NeoSpace.sm),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.lg,
              0,
              NeoSpace.md,
              NeoSpace.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Albums',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: c.inkMuted,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _tout = !_tout),
                  child: Text(_tout ? 'Réduire' : 'Voir tout'),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<GalleryAlbum>>(
              future: _albums,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final albums = snap.data ?? const <GalleryAlbum>[];
                if (albums.isEmpty) {
                  return Center(
                    child: Text(
                      'Aucun album.',
                      style: TextStyle(color: c.inkMuted),
                    ),
                  );
                }
                final tuile =
                    (MediaQuery.sizeOf(context).width - 4 * NeoSpace.md) / 3;
                if (_tout) {
                  return GridView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NeoSpace.md,
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: NeoSpace.md,
                          crossAxisSpacing: NeoSpace.md,
                          // Une vignette carrée, son nom et son compte.
                          childAspectRatio: 0.74,
                        ),
                    itemCount: albums.length,
                    itemBuilder: (context, i) => _tuile(albums[i]),
                  );
                }
                // Deux rangées, qui défilent à l'horizontale.
                return GridView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: NeoSpace.md,
                    crossAxisSpacing: NeoSpace.md,
                    childAspectRatio: 1 / 0.74,
                  ),
                  itemCount: albums.length,
                  itemBuilder: (context, i) =>
                      SizedBox(width: tuile, child: _tuile(albums[i])),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tuile(GalleryAlbum album) => _Album(
    album: album,
    feed: widget.feed,
    choisi: album.id == widget.courant.album?.id,
    onTap: () => Navigator.pop(context, GalleryFilter(album: album)),
  );
}

/// Récent · Photos · Vidéos : un rond, un mot.
class _Raccourci extends StatelessWidget {
  const _Raccourci({
    required this.filtre,
    required this.choisi,
    required this.onTap,
  });

  final GalleryFilter filtre;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final icone = switch (filtre.mediaType) {
      'image' => Icons.image_outlined,
      'video' => Icons.play_circle_outline,
      _ => Icons.collections_outlined,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NeoSpace.sm),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surface,
                border: choisi ? Border.all(color: c.ink, width: 2) : null,
              ),
              child: Icon(icone, color: c.ink),
            ),
            const SizedBox(height: NeoSpace.xs + 2),
            Text(
              filtre.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: choisi ? FontWeight.w700 : FontWeight.w500,
                color: c.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un dossier : sa couverture, son nom, son compte.
class _Album extends StatelessWidget {
  const _Album({
    required this.album,
    required this.feed,
    required this.choisi,
    required this.onTap,
  });

  final GalleryAlbum album;
  final GalleryFeed feed;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final uri = album.coverUri;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                foregroundDecoration: choisi
                    ? BoxDecoration(
                        border: Border.all(color: c.ink, width: 2.5),
                        borderRadius: BorderRadius.circular(10),
                      )
                    : null,
                color: c.surface,
                child: uri == null
                    ? null
                    : FutureBuilder(
                        // La même vignette que la grille, depuis le même
                        // cache.
                        future: feed.thumbnail(uri, size: 256),
                        builder: (context, snap) => snap.hasData
                            ? Image.memory(
                                snap.data!,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                height: double.infinity,
                                gaplessPlayback: true,
                              )
                            : const SizedBox.shrink(),
                      ),
              ),
            ),
          ),
          const SizedBox(height: NeoSpace.xs + 2),
          Text(
            album.name,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          Text(
            '${album.count}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: c.inkMuted),
          ),
        ],
      ),
    );
  }
}
