import 'package:flutter/material.dart';

import '../models/card.dart';

/// Pastille du type d'une Vibe (standard, Oneshot, One of One, BeReal).
///
/// Vit dans `core/widgets` depuis le 2026-08-11. Elle était jusque-là déclarée
/// dans `card_viewer_screen.dart` et rendue publique « parce que la visionneuse
/// de stories en avait besoin » — ce qui obligeait les stories à importer tout
/// l'écran de lecture des Cards pour afficher une étiquette. C'est un habillage
/// du type, pas une pièce de la visionneuse : sa place est ici.
class CardTypeBadge extends StatelessWidget {
  const CardTypeBadge({super.key, required this.type, this.fontSize = 16});
  final CardType type;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final compact = fontSize < 14;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        gradient: type.gradient,
        border: type.gradient == null
            ? Border.all(color: type.color, width: compact ? 1.5 : 2)
            : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        type.tag,
        style: TextStyle(
          color: type.gradient == null ? type.color : Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        ),
      ),
    );
  }
}

/// La pastille d'un **Flow** — une vidéo publiée seule (Jay, 2026-09-17).
///
/// Elle existe pour que la **requalification se voie** : l'app décide toute
/// seule qu'une vidéo seule est un Flow, et une décision prise à la place de
/// quelqu'un doit au moins lui être dite. Sobre : ce n'est pas un type de
/// Vibe, ça ne prend pas ses couleurs.
class FlowBadge extends StatelessWidget {
  const FlowBadge({super.key, this.fontSize = 9});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: fontSize < 12 ? 7 : 10,
        vertical: fontSize < 12 ? 2 : 4,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: ink.withValues(alpha: 0.45), width: 1.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Flow',
        style: TextStyle(
          color: ink,
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        ),
      ),
    );
  }
}
