import 'package:flutter/material.dart';

/// **Les mesures d'un bouton d'action de contenu** — aimer, enregistrer,
/// partager, le menu. Deux tailles, une seule définition :
///
/// - **pleine** : sur la carte en plein écran, où le doigt a de la place ;
/// - **resserrée** (`dense`) : dans l'en-tête d'une cellule du fil, où la
///   ligne est partagée avec l'avatar, le pseudo et la date (Jay, 2026-09-16 :
///   les actions montent en haut à droite pour que tout le contenu tienne
///   dans un écran).
///
/// ⚠️ Elles vivent ici et pas dans chaque bouton : trois boutons qui se
/// règlent chacun de leur côté finissent par ne plus avoir la même taille sur
/// la même ligne — et ça ne lève aucune erreur, ça se voit seulement à l'œil.
abstract final class ActionMetrics {
  static double icon(bool dense) => dense ? 21 : 24;
  static EdgeInsets padding(bool dense) => EdgeInsets.all(dense ? 6 : 8);
  static BoxConstraints? constraints(bool dense) =>
      dense ? const BoxConstraints(minWidth: 34, minHeight: 34) : null;
}

/// Un bouton d'action, aux mesures d'[ActionMetrics].
class ActionIconButton extends StatelessWidget {
  const ActionIconButton({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.dense = false,
  });

  final Widget icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool dense;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: icon,
    color: color,
    tooltip: tooltip,
    onPressed: onPressed,
    iconSize: ActionMetrics.icon(dense),
    padding: ActionMetrics.padding(dense),
    constraints: ActionMetrics.constraints(dense),
    visualDensity: dense ? VisualDensity.compact : null,
  );
}
