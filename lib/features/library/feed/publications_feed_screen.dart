import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/likes.dart';
import '../../../core/models/library_item.dart';
import '../../../core/typography.dart';
import 'active_item_tracker.dart';
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
  final _scroll = ScrollController();
  final _cellKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    // Les likes de tout le fil, en un aller-retour.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(likesStoreProvider.notifier).load(_items.map((i) => i.id));
      _jumpToInitial();
    });
  }

  /// Se poser sur la publication touchée : les cellules ont des hauteurs
  /// différentes (un album 3:4, une Vibe 9:16), on ne peut pas calculer
  /// l'offset — on laisse la première image se poser, puis on aligne.
  void _jumpToInitial() {
    if (widget.initialIndex <= 0) return;
    final key = _cellKeys[_items[widget.initialIndex].id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0);
      return;
    }
    // Pas encore construite (hors de la fenêtre) : on estime, puis on
    // réaligne une fois qu'elle existe.
    final size = MediaQuery.sizeOf(context);
    var offset = 0.0;
    for (var i = 0; i < widget.initialIndex; i++) {
      final it = _items[i];
      offset += it.isAlbum
          ? size.width / (it.aspect ?? AlbumAspect.tall).ratio + 150
          : size.height * 0.72 + 150;
    }
    _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = key?.currentContext;
      if (c != null && mounted) Scrollable.ensureVisible(c, alignment: 0);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _openVibe(LibraryItem item) {
    final vibes = _items.where((i) => !i.isAlbum).toList();
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
    setState(() => _items = _items.where((i) => i.id != item.id).toList());
    if (_items.isEmpty) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ActiveItemTracker(
        child: _FeedList(
          items: _items,
          scroll: _scroll,
          keyFor: (id) => _cellKeys.putIfAbsent(id, GlobalKey.new),
          onOpenVibe: _openVibe,
          onDeleted: _removed,
        ),
      ),
    );
  }
}

class _FeedList extends StatelessWidget {
  const _FeedList({
    required this.items,
    required this.scroll,
    required this.keyFor,
    required this.onOpenVibe,
    required this.onDeleted,
  });

  final List<LibraryItem> items;
  final ScrollController scroll;
  final GlobalKey Function(String id) keyFor;
  final ValueChanged<LibraryItem> onOpenVibe;
  final ValueChanged<LibraryItem> onDeleted;

  @override
  Widget build(BuildContext context) {
    final tracker = ActiveItemTracker.of(context);
    return ListView.builder(
      controller: scroll,
      // Les cellules voisines sont construites d'avance : leurs médias se
      // déchiffrent avant d'entrer à l'écran.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      padding: const EdgeInsets.only(bottom: NeoSpace.xxl),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return TrackedItem(
          key: keyFor(item.id),
          id: item.id,
          child: ValueListenableBuilder<String?>(
            valueListenable: tracker.active,
            builder: (context, active, _) => PublicationCell(
              item: item,
              active: active == item.id,
              onOpenVibe: () => onOpenVibe(item),
              onDeleted: () => onDeleted(item),
            ),
          ),
        );
      },
    );
  }
}
