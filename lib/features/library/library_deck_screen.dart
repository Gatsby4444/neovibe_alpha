import 'package:flutter/material.dart';

import '../../core/models/library_item.dart';
import 'mini_card.dart';

/// Bibliothèque en **deck** (consigne Jay 2026-07-25) : une mini-card au
/// centre, les voisines qui dépassent, et on défile en swipant.
///
/// Répartition des gestes, imposée par le deck lui-même :
/// - **swipe horizontal** → card suivante / précédente (c'est le deck) ;
/// - **swipe vertical** sur la card → la retourne (l'horizontale est prise) ;
/// - **clic** → ouvre en grand.
///
/// En grille, le retournement se fait à l'horizontale : là, c'est la verticale
/// qui est prise par le défilement. Le principe « swipe = retourner, clic =
/// ouvrir » reste le même dans les deux vues.
class LibraryDeckScreen extends StatefulWidget {
  const LibraryDeckScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.title = 'Bibliothèque',
  });

  final List<LibraryItem> items;
  final int initialIndex;
  final String title;

  @override
  State<LibraryDeckScreen> createState() => _LibraryDeckScreenState();
}

class _LibraryDeckScreenState extends State<LibraryDeckScreen> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
    viewportFraction: 0.74,
  );
  late double _page = widget.initialIndex.toDouble();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      // `page` est nul tant que la première mesure n'a pas eu lieu.
      final p = _controller.page;
      if (p != null && p != _page) setState(() => _page = p);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.items.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_page.round() + 1} / $count',
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: count,
              itemBuilder: (context, index) {
                // Les voisines rapetissent : la card regardée est au premier
                // plan, sans masquer qu'il y en a d'autres derrière.
                final distance = (_page - index).abs().clamp(0.0, 1.0);
                final scale = 1 - distance * 0.14;
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 28,
                    ),
                    child: Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: 1 - distance * 0.35,
                        child: MiniCard(
                          item: widget.items[index],
                          // L'horizontale appartient au deck : on retourne à la
                          // verticale.
                          flipAxis: Axis.vertical,
                          decodeWidth: 900,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Text(
              'Swipe ↕ pour retourner · clic pour ouvrir',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
