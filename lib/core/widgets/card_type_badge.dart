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
