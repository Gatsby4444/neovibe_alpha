import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/likes.dart';
import '../../../core/models/library_item.dart';
import '../../../core/typography.dart';
import '../../../core/widgets/anchor_scope.dart';
import '../../../core/widgets/anchored_list.dart';
import '../../../core/widgets/cover_host.dart';
import 'active_item_tracker.dart';
import 'flows_reel_screen.dart';
import 'publication_cell.dart';
import 'vibes_reel_screen.dart';
import '../../../core/widgets/reel_route.dart';

/// Ouvre le fil posé sur `items[initialIndex]`.
///
/// **En couverture du profil** ([CoverHost]) quand il y en a un : la barre de
/// navigation reste, et un balayage vers la droite découvre le profil (Jay,
/// 2026-09-19). Sans hôte, en page — le comportement d'avant.
void openPublications(
  BuildContext context, {
  required List<LibraryItem> items,
  required int initialIndex,
  String title = 'Publications',
}) {
  final host = CoverHost.maybeOf(context);
  if (host != null) {
    host.show(
      PublicationsFeedScreen(
        items: items,
        initialIndex: initialIndex,
        title: title,
        onClose: host.hide,
      ),
    );
    return;
  }
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
    this.titleWidget,
    this.actions = const [],
    this.revealAdders = false,
    this.onClose,
  });

  /// Les publications, dans l'ordre du profil.
  final List<LibraryItem> items;
  final int initialIndex;
  final String title;

  /// À la place du titre : le sélecteur d'un fil de Pulse (2026-09-20).
  final Widget? titleWidget;

  /// À droite du bandeau (le bouton « relire ma position »).
  final List<Widget> actions;

  /// Un fil de Pulse : sous le pseudo, « Ajouté par X » une fois liké.
  final bool revealAdders;

  /// Fermer le fil. Nul = le fil est une page, la flèche la dépile.
  final VoidCallback? onClose;

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

  /// Le bandeau « ← Publications » : il se cache quand on descend, revient
  /// dès qu'on remonte un peu, et reste quand on est en haut (Jay,
  /// 2026-09-19 : *« comme les menus de navigation de certains sites web »*).
  var _bannerVisible = true;

  bool _onScroll(ScrollNotification n) {
    // Seul le fil lui-même : les carrousels, dedans, défilent à l'horizontale.
    if (n.metrics.axis != Axis.vertical) return false;
    final enHaut = n.metrics.pixels <= n.metrics.minScrollExtent + 1;
    bool? visible;
    if (n is UserScrollNotification) {
      visible = switch (n.direction) {
        ScrollDirection.reverse => false,
        ScrollDirection.forward => true,
        ScrollDirection.idle => enHaut ? true : null,
      };
    } else if (n is ScrollUpdateNotification && enHaut) {
      visible = true;
    }
    if (visible != null && visible != _bannerVisible) {
      setState(() => _bannerVisible = visible!);
    }
    return false;
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }

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
    // Le plein écran reçoit NOTRE registre de positions : c'est sur nos
    // cellules qu'il se refermera (voir [AnchorScope]).
    final anchors = _anchorsKey.currentState;
    if (item.isFlow) {
      final flows = _items.where((i) => i.isFlow).toList();
      final index = flows.indexWhere((i) => i.id == item.id);
      if (index < 0) return;
      Navigator.of(context).push(
        ReelRoute(
          builder: (_) => FlowsReelScreen(
            flows: flows,
            initialIndex: index,
            anchors: anchors,
          ),
        ),
      );
      return;
    }
    final vibes = _items.where((i) => !i.isPublication).toList();
    final index = vibes.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    Navigator.of(context).push(
      ReelRoute(
        builder: (_) => VibesReelScreen(
          vibes: vibes,
          initialIndex: index,
          anchors: anchors,
        ),
      ),
    );
  }

  final _anchorsKey = GlobalKey<AnchorScopeState>();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Le plein écran demande à voir ce contenu : le fil se **repose** dessus
  /// (la cellule devient l'origine du défilement, comme à l'ouverture). C'est
  /// ce qui fait que la rétraction a une cible, et qu'après fermeture on
  /// retrouve le fil sur la Vibe qu'on regardait.
  void _reveal(String id) {
    final index = _items.indexWhere((i) => i.id == id);
    if (index < 0 || index == _anchor) return;
    setState(() => _anchor = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
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

  /// La légende d'une publication a changé : on remplace l'exemplaire qu'on
  /// tient — la liste reçue à l'ouverture est une copie, elle ne se met pas
  /// à jour toute seule.
  void _changed(LibraryItem item) {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    setState(() => _items = List.of(_items)..[index] = item);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Banner(
              title: widget.title,
              titleWidget: widget.titleWidget,
              actions: widget.actions,
              visible: _bannerVisible,
              onClose: _close,
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: AnchorScope(
                  key: _anchorsKey,
                  onReveal: _reveal,
                  child: ActiveItemTracker(
                    child: _FeedList(
                      items: _items,
                      anchor: _anchor,
                      controller: _scroll,
                      onOpen: _ouvrirEnGrand,
                      onDeleted: _removed,
                      onChanged: _changed,
                      revealAdders: widget.revealAdders,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le bandeau du fil : la flèche et le titre, sur une hauteur qui se replie.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.title,
    required this.visible,
    required this.onClose,
    this.titleWidget,
    this.actions = const [],
  });

  final String title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final bool visible;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      height: visible ? kToolbarHeight : 0,
      child: ClipRect(
        child: OverflowBox(
          maxHeight: kToolbarHeight,
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Retour',
                  onPressed: onClose,
                ),
                Expanded(
                  child:
                      titleWidget ??
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            theme.appBarTheme.titleTextStyle ??
                            theme.textTheme.titleLarge,
                      ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedList extends StatelessWidget {
  const _FeedList({
    required this.items,
    required this.anchor,
    required this.controller,
    required this.onOpen,
    required this.onDeleted,
    required this.onChanged,
    this.revealAdders = false,
  });

  final List<LibraryItem> items;
  final int anchor;
  final ScrollController controller;
  final ValueChanged<LibraryItem> onOpen;
  final ValueChanged<LibraryItem> onDeleted;
  final ValueChanged<LibraryItem> onChanged;
  final bool revealAdders;

  @override
  Widget build(BuildContext context) {
    final tracker = ActiveItemTracker.of(context);
    return AnchoredList(
      itemCount: items.length,
      anchorIndex: anchor,
      controller: controller,
      // Les cellules voisines sont construites d'avance : leurs médias se
      // déchiffrent avant d'entrer à l'écran.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      bottomPadding: NeoSpace.xxl,
      itemBuilder: (context, i) {
        final item = items[i];
        return TrackedItem(
          key: ValueKey(item.id),
          id: item.id,
          child: Anchored(
            id: item.id,
            child: ValueListenableBuilder<String?>(
              valueListenable: tracker.active,
              builder: (context, active, _) => PublicationCell(
                item: item,
                active: active == item.id,
                onOpen: () => onOpen(item),
                onDeleted: () => onDeleted(item),
                onChanged: onChanged,
                revealAdder: revealAdders,
              ),
            ),
          ),
        );
      },
    );
  }
}
