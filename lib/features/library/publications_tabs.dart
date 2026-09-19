import 'package:flutter/material.dart';

import '../../core/models/library_item.dart';
import '../../core/theme.dart';
import '../../core/widgets/anchor_scope.dart';
import '../../core/widgets/vibe_face.dart';
import 'feed/flows_reel_screen.dart';
import 'feed/publications_feed_screen.dart';
import 'feed/vibes_reel_screen.dart';
import 'mini_card.dart';
import '../../core/widgets/reel_route.dart';

/// **Les deux onglets d'un profil**, comme sur Instagram (Jay, 2026-09-17) :
///
/// | Onglet | Ce qu'il montre | Ce qu'un appui ouvre |
/// |---|---|---|
/// | **la grille** | tout : publications, Vibes et Flows | le **fil**, posé sur la case touchée |
/// | **les Vibes** | les Vibes seules, **à leur format** (9:16) | le **plein écran** des Vibes |
/// | **les Flows** | les vidéos publiées seules | le **plein écran** des Flows, façon Reels |
///
/// C'est la même séparation que chez eux entre la grille et l'onglet Reels —
/// *« nous on n'a pas de Reels, on a des Vibes, et c'est ça nos Reels »*. Les
/// deux autres onglets d'Instagram (republications, mentions) ne nous servent
/// à rien.
///
/// ⚠️ **Deux onglets, deux destinations — et c'est voulu.** Un contenu ne
/// change pas, sa présentation oui : dans la grille, une Vibe est une
/// publication parmi d'autres, recadrée en 4:5 comme les autres, et elle
/// s'ouvre dans le fil ; dans l'onglet Vibes, elle est ce qu'elle est
/// vraiment, un 9:16 plein écran.
class PublicationsTabs extends StatefulWidget {
  const PublicationsTabs({
    super.key,
    required this.items,
    required this.feedTitle,
    required this.emptyMessage,
    this.padding = const EdgeInsets.fromLTRB(10, 0, 10, 80),
    this.onLongPress,
  });

  /// Toutes les publications du profil, dans l'ordre.
  final List<LibraryItem> items;

  /// Le titre du fil ouvert depuis la grille (le pseudo, chez quelqu'un
  /// d'autre).
  final String feedTitle;

  /// Ce qu'on lit quand il n'y a rien du tout.
  final String emptyMessage;

  final EdgeInsets padding;

  /// Appui long sur une case (retirer, sur mon propre profil).
  final void Function(LibraryItem item)? onLongPress;

  @override
  State<PublicationsTabs> createState() => _PublicationsTabsState();
}

enum _Onglet {
  tout(Icons.grid_on_outlined, 'Tout'),
  vibes(Icons.style_outlined, 'Vibes'),
  flows(Icons.play_circle_outline, 'Flows');

  const _Onglet(this.icon, this.label);
  final IconData icon;
  final String label;
}

class _PublicationsTabsState extends State<PublicationsTabs> {
  var _onglet = _Onglet.tout;
  final _anchorsKey = GlobalKey<AnchorScopeState>();

  /// Le plein écran demande à voir ce contenu : la case défile en vue, au
  /// milieu — c'est là que la rétraction viendra se poser.
  void _reveal(String id) {
    final ctx = _anchorsKey.currentState?.contextOf(id);
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final liste = switch (_onglet) {
      _Onglet.tout => widget.items,
      _Onglet.vibes => widget.items.where((i) => !i.isPublication).toList(),
      _Onglet.flows => widget.items.where((i) => i.isFlow).toList(),
    };
    // La grille de tout recadre en 4:5 ; l'onglet Vibes montre les cartes à
    // LEUR format — c'est ce qui fait comprendre qu'on n'y trouve que ça.
    // Les Flows gardent le 4:5 : ils sont publiés à leur format, pas au 9:16.
    final ratio = _onglet == _Onglet.vibes ? kVibeFaceRatio : kMiniCardRatio;

    return AnchorScope(
      key: _anchorsKey,
      onReveal: _reveal,
      child: Column(
        children: [
          _Barre(courant: _onglet, onTap: (o) => setState(() => _onglet = o)),
          if (liste.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                switch (_onglet) {
                  _Onglet.tout => widget.emptyMessage,
                  _Onglet.vibes => 'Aucune Vibe publiée pour l\'instant.',
                  _Onglet.flows => 'Aucun Flow publié pour l\'instant.',
                },
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: widget.padding,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: ratio,
              ),
              itemCount: liste.length,
              itemBuilder: (context, index) => Anchored(
                id: liste[index].id,
                child: MiniCard(
                  item: liste[index],
                  ratio: ratio,
                  onTap: () => _ouvrir(liste, index),
                  onLongPress: widget.onLongPress == null
                      ? null
                      : () => widget.onLongPress!(liste[index]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _ouvrir(List<LibraryItem> liste, int index) {
    switch (_onglet) {
      // La grille mène au fil, où les formats se suivent.
      case _Onglet.tout:
        openPublications(
          context,
          items: liste,
          initialIndex: index,
          title: widget.feedTitle,
        );
      // Les deux autres onglets mènent droit au plein écran : c'est leur
      // format qui fait l'onglet, autant le montrer tout de suite.
      case _Onglet.vibes:
        Navigator.of(context).push(
          ReelRoute(
            builder: (_) => VibesReelScreen(
              vibes: liste,
              initialIndex: index,
              anchors: _anchorsKey.currentState,
            ),
          ),
        );
      case _Onglet.flows:
        Navigator.of(context).push(
          ReelRoute(
            builder: (_) => FlowsReelScreen(
              flows: liste,
              initialIndex: index,
              anchors: _anchorsKey.currentState,
            ),
          ),
        );
    }
  }
}

/// La barre des deux onglets : l'icône du courant est encrée et soulignée.
class _Barre extends StatelessWidget {
  const _Barre({required this.courant, required this.onTap});

  final _Onglet courant;
  final ValueChanged<_Onglet> onTap;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        for (final o in _Onglet.values)
          Expanded(
            child: InkWell(
              onTap: () => onTap(o),
              child: Tooltip(
                message: o.label,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 2,
                        color: o == courant ? ink : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Icon(
                    o.icon,
                    size: 24,
                    color: o == courant ? ink : context.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
