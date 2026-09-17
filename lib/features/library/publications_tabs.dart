import 'package:flutter/material.dart';

import '../../core/models/library_item.dart';
import '../../core/theme.dart';
import '../../core/widgets/vibe_face.dart';
import 'feed/publications_feed_screen.dart';
import 'feed/vibes_reel_screen.dart';
import 'mini_card.dart';

/// **Les deux onglets d'un profil**, comme sur Instagram (Jay, 2026-09-17) :
///
/// | Onglet | Ce qu'il montre | Ce qu'un appui ouvre |
/// |---|---|---|
/// | **la grille** | tout, publications et Vibes mêlées | le **fil**, posé sur la case touchée |
/// | **les Vibes** | les Vibes seules | le **plein écran**, posé sur celle-là |
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
  vibes(Icons.style_outlined, 'Vibes');

  const _Onglet(this.icon, this.label);
  final IconData icon;
  final String label;
}

class _PublicationsTabsState extends State<PublicationsTabs> {
  var _onglet = _Onglet.tout;

  @override
  Widget build(BuildContext context) {
    final vibes = widget.items.where((i) => !i.isPublication).toList();
    final liste = _onglet == _Onglet.tout ? widget.items : vibes;
    // La grille de tout recadre en 4:5 ; l'onglet Vibes montre les cartes à
    // LEUR format — c'est ce qui fait comprendre qu'on n'y trouve que ça.
    final ratio = _onglet == _Onglet.tout ? kMiniCardRatio : kVibeFaceRatio;

    return Column(
      children: [
        _Barre(courant: _onglet, onTap: (o) => setState(() => _onglet = o)),
        if (liste.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              _onglet == _Onglet.tout
                  ? widget.emptyMessage
                  : 'Aucune Vibe publiée pour l\'instant.',
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
            itemBuilder: (context, index) => MiniCard(
              item: liste[index],
              ratio: ratio,
              onTap: () => _ouvrir(liste, index),
              onLongPress: widget.onLongPress == null
                  ? null
                  : () => widget.onLongPress!(liste[index]),
            ),
          ),
      ],
    );
  }

  void _ouvrir(List<LibraryItem> liste, int index) {
    if (_onglet == _Onglet.tout) {
      openPublications(
        context,
        items: liste,
        initialIndex: index,
        title: widget.feedTitle,
      );
      return;
    }
    // L'onglet Vibes mène droit au plein écran : c'est son format.
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VibesReelScreen(vibes: liste, initialIndex: index),
      ),
    );
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
