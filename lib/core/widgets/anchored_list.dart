import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

/// **Une liste qui s'ouvre pile sur l'un de ses éléments.**
///
/// Ouvrir une liste sur son n-ième élément demande de savoir où il commence,
/// donc la hauteur de tous ceux d'avant. Quand les éléments n'ont pas la même
/// hauteur — une Vibe 9:16, un album 3:4, une légende de trois lignes — cette
/// hauteur ne se calcule pas : elle ne s'apprend qu'une fois l'élément
/// construit, et un élément hors de la fenêtre n'est pas construit.
///
/// ⚠️ **Estimer puis corriger ne marche qu'à courte distance.** La correction
/// ne peut avoir lieu que si l'estimation est tombée assez près pour que
/// l'élément visé soit bâti ; l'erreur s'accumulant à chaque élément, au-delà
/// d'une vingtaine la cellule visée n'existe pas — et plus rien ne corrige,
/// **sans la moindre erreur levée**. C'est exactement ce que Jay a vu le
/// 2026-09-16 : le fil du profil s'ouvrait à côté de la publication touchée.
///
/// Ici il n'y a rien à estimer : l'élément d'ancrage **est** l'origine du
/// défilement (`CustomScrollView.center`). Ceux d'avant vivent aux décalages
/// négatifs, construits seulement si on remonte. Le résultat est exact quels
/// que soient le nombre d'éléments et leurs hauteurs — c'est la cause qui
/// disparaît, pas le symptôme qu'on rattrape.
///
/// [anchorIndex] appartient à l'appelant : si la liste change (une
/// publication retirée), c'est à lui de le recaler sur le **même** élément,
/// sans quoi l'origine glisse d'un cran.
class AnchoredList extends StatefulWidget {
  const AnchoredList({
    super.key,
    required this.itemCount,
    required this.anchorIndex,
    required this.itemBuilder,
    this.controller,
    this.scrollCacheExtent,
    this.bottomPadding = 0,
  });

  final int itemCount;

  /// L'élément posé en haut de la fenêtre à l'ouverture.
  final int anchorIndex;

  final NullableIndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final ScrollCacheExtent? scrollCacheExtent;

  /// De l'air après le dernier élément.
  final double bottomPadding;

  @override
  State<AnchoredList> createState() => _AnchoredListState();
}

class _AnchoredListState extends State<AnchoredList> {
  /// L'identité du sliver d'origine : stable pour la vie du widget.
  final _center = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final count = widget.itemCount;
    final anchor = count == 0 ? 0 : widget.anchorIndex.clamp(0, count - 1);
    return CustomScrollView(
      controller: widget.controller,
      center: _center,
      scrollCacheExtent: widget.scrollCacheExtent,
      slivers: [
        // Avant l'ancre : construit de bas en haut (l'élément 0 de ce sliver
        // est le voisin immédiat de l'ancre).
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => widget.itemBuilder(context, anchor - 1 - i),
            childCount: anchor,
          ),
        ),
        SliverList(
          key: _center,
          delegate: SliverChildBuilderDelegate(
            (context, i) => widget.itemBuilder(context, anchor + i),
            childCount: count - anchor,
          ),
        ),
        if (widget.bottomPadding > 0)
          SliverToBoxAdapter(child: SizedBox(height: widget.bottomPadding)),
      ],
    );
  }
}
