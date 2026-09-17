import 'package:flutter/material.dart';

/// **La route d'un plein écran : elle s'ouvre normalement et se ferme
/// TOUT DE SUITE.**
///
/// Jay, 2026-09-18 : *« il y a un délai trop long entre le moment de la
/// réduction et l'affichage de l'écran du dessous, il faut que cela soit
/// perçu comme instantané. Je ne parle pas de la vitesse de l'animation de
/// réduction mais de la transition entre le moment où la réduction est
/// confirmée et l'apparition de l'écran d'en dessous. »*
///
/// Ce qu'il voyait : la rétraction (260 ms) **puis** la transition de sortie
/// d'une `MaterialPageRoute` (300 ms, un glissement) — deux animations à la
/// suite pour un seul geste. Et comme le plein écran est noir et opaque, la
/// seconde ne montre rien pendant sa première moitié.
///
/// Ici, la sortie dure [sortie] et c'est un **fondu** : l'écran d'en dessous
/// est déjà là quand la rétraction finit. L'ouverture, elle, garde son temps —
/// c'est l'entrée dans un espace, pas un retour.
class ReelRoute<T> extends PageRouteBuilder<T> {
  ReelRoute({required WidgetBuilder builder, super.settings})
    : super(
        pageBuilder: (context, _, _) => builder(context),
        fullscreenDialog: true,
        opaque: true,
        transitionDuration: entree,
        reverseTransitionDuration: sortie,
        transitionsBuilder: (context, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      );

  static const entree = Duration(milliseconds: 220);

  /// Assez bref pour ne pas se voir, assez long pour ne pas clignoter.
  static const sortie = Duration(milliseconds: 80);
}
