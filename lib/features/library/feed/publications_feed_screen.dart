import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/likes.dart';
import '../../../core/models/library_item.dart';
import '../../../core/typography.dart';
import '../../../core/widgets/anchored_list.dart';
import 'active_item_tracker.dart';
import 'flows_reel_screen.dart';
import 'publication_cell.dart';
import 'vibes_reel_screen.dart';

/// Ouvre le fil posé sur `items[initialIndex]`.
void openPublications(
  BuildContext context, {
  required List<LibraryItem> items,
  required int initialIndex,
  String title = 'Publications',
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PublicationsFeedScreen(
        items: items,
        initialIndex: initialIndex,
        title: title,
      ),
    ),
  );
}

/// **Les publications d'un profil, à la suite** — comme Instagram : on touche
/// une case de la grille, et on arrive sur la page qui défile verticalement,
/// posée sur cette publication, avec toutes les autres avant et après, Cards
/// et albums mêlés. Chaque publication est une [PublicationCell].
///
/// « Posée sur cette publication » est exact, et pas approché : la
/// publication touchée est l'**origine** du défilement ([AnchoredList]), pas
/// une position estimée d'après la hauteur des précédentes. Des cellules de
/// hauteurs différentes ne se devinent pas.
///
/// Une Vibe touchée s'ouvre en plein écran façon Reels (`VibesReelScreen`)
/// sur les Vibes de ce profil. Pas de « tirer pour fermer » ici : c'est une
/// liste, le geste vertical lui appartient ; la flèche de la barre ferme.
class PublicationsFeedScreen extends ConsumerStatefulWidget {
  const PublicationsFeedScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    this.title = 'Publications',
  });

  /// Les publications, dans l'ordre du profil.
  final List<LibraryItem> items;
  final int initialIndex;
  final String title;

  @override
  ConsumerState<PublicationsFeedScreen> createState() =>
      _PublicationsFeedScreenState();
}

class _PublicationsFeedScreenState
    extends ConsumerState<PublicationsFeedScreen> {
  late List<LibraryItem> _items = List.of(widget.items);

  /// La publication sur laquelle le fil est posé — elle suit son élément, pas
  /// son rang : retirer une publication d'avant décale tout le reste.
  late int _anchor = widget.initialIndex;

  @override
  void initState() {
    super.initState();
    // Les likes de tout le fil, en un aller-retour.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(likesStoreProvider.notifier).load(_items.map((i) => i.id));
      }
    });
  }

  /// **Ouvrir en grand ce qu'on vient de toucher** — dans le plein écran de
  /// SON format : les Vibes entre elles, les Flows entre eux (Jay,
  /// 2026-09-17). Un carrousel, lui, se lit dans le fil : il n'a pas de plein
  /// écran à lui.
  void _ouvrirEnGrand(LibraryItem item) {
    if (item.isFlow) {
      final flows = _items.where((i) => i.isFlow).toList();
      final index = flows.indexWhere((i) => i.id == item.id);
      if (index < 0) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => FlowsReelScreen(flows: flows, initialIndex: index),
        ),
      );
      return;
    }
    final vibes = _items.where((i) => !i.isPublication).toList();
    final index = vibes.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VibesReelScreen(vibes: vibes, initialIndex: index),
      ),
    );
  }

  void _removed(LibraryItem item) {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    setState(() {
      _items = List.of(_items)..removeAt(index);
      if (index < _anchor) _anchor -= 1;
    });
    if (_items.isEmpty) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ActiveItemTracker(
        child: _FeedList(
          items: _items,
          anchor: _anchor,
          onOpen: _ouvrirEnGrand,
          onDeleted: _removed,
        ),
      ),
    );
  }
}

class _FeedList extends StatelessWidget {
  const _FeedList({
    required this.items,
    required this.anchor,
    required this.onOpen,
    required this.onDeleted,
  });

  final List<LibraryItem> items;
  final int anchor;
  final ValueChanged<LibraryItem> onOpen;
  final ValueChanged<LibraryItem> onDeleted;

  @override
  Widget build(BuildContext context) {
    final tracker = ActiveItemTracker.of(context);
    return AnchoredList(
      itemCount: items.length,
      anchorIndex: anchor,
      // Les cellules voisines sont construites d'avance : leurs médias se
      // déchiffrent avant d'entrer à l'écran.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      bottomPadding: NeoSpace.xxl,
      itemBuilder: (context, i) {
        final item = items[i];
        return TrackedItem(
          key: ValueKey(item.id),
          id: item.id,
          child: ValueListenableBuilder<String?>(
            valueListenable: tracker.active,
            builder: (context, active, _) => PublicationCell(
              item: item,
              active: active == item.id,
              onOpen: () => onOpen(item),
              onDeleted: () => onDeleted(item),
            ),
          ),
        );
      },
    );
  }
}
