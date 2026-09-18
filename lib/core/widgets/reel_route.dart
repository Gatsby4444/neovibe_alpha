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
///
/// ### Une superposition, pas une page (Jay, 2026-09-18)
///
/// *« Lorsqu'on referme en dézoomant le fond est noir et cela fait bizarre,
/// ce serait bien si on pouvait voir en dessous directement l'écran profil.
/// Cela veut dire que le plein écran serait un peu comme une superposition. »*
///
/// La route n'est donc **pas opaque** : l'écran d'en dessous reste dessiné,
/// et c'est le plein écran lui-même qui porte son noir — DANS ce qui se
/// rétracte (`PinchToClose` enveloppe un fond noir, le `Scaffold` est
/// transparent). Quand l'heptagone se referme, c'est le profil qu'on voit
/// autour ; à l'ouverture, le fondu pose le noir sur le profil au lieu de le
/// remplacer.
///
/// Le prix : l'écran du dessous continue d'être peint tant que le plein
/// écran est ouvert — négligeable pour une grille immobile — et tout ce qui
/// y vit doit se savoir **recouvert** (le fil se tait sous un plein écran,
/// `ActiveItemTracker`, même jour).
class ReelRoute<T> extends PageRouteBuilder<T> {
  ReelRoute({required WidgetBuilder builder, super.settings})
    : super(
        pageBuilder: (context, _, _) => builder(context),
        fullscreenDialog: true,
        opaque: false,
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
