import 'package:flutter/material.dart';

/// Le système de mouvement de NeoVibe.
///
/// Posé le 2026-08-14, avant toute nouvelle pièce d'interface (Rive comprise).
///
/// ## Pourquoi ça existe
///
/// Avant : **vingt durées distinctes** dans l'app — 40, 50, 100, 140, 150, 160,
/// 180, 220, 260, 280, 300, 320, 340, 350, 380, 400, 520… Chaque écran avait
/// été réglé seul, à l'oreille, au moment où il était écrit. Aucun n'était
/// faux ; l'ensemble n'avait aucun accord.
///
/// C'est le vrai obstacle au « premium » : **le sentiment de finition vient de
/// la cohérence, pas du nombre d'animations.** Ajouter des composants animés
/// par-dessus vingt tempos différents ne donne pas une app soignée, ça donne un
/// patchwork plus cher.
///
/// ## La règle : le palier suit la DISTANCE parcourue
///
/// Pas l'importance de l'action, pas le goût du moment — la distance. C'est ce
/// qui rend le choix décidable par quelqu'un d'autre que celui qui a écrit
/// l'écran, et c'est tout l'intérêt d'un système.
///
/// | Palier | Durée | Ce qui bouge |
/// |---|---|---|
/// | [fast] | 120 ms | Rien ne se déplace : opacité, couleur, bascule, retour d'appui |
/// | [normal] | 220 ms | Déplacement local : menu qui se déplie, bandeau, élément de liste |
/// | [ample] | 380 ms | Déplacement plein écran : navigation, retournement d'une Vibe |
///
/// ## Ce qui est délibérément HORS système
///
/// Trois familles, à ne jamais rattraper « pour harmoniser » :
///
/// 1. **Les seuils de geste** — la durée d'un `LongPressGestureRecognizer` dit
///    combien de temps le doigt doit rester. Ce n'est pas du mouvement, c'est
///    la définition du geste : la changer change ce que l'utilisateur doit
///    faire.
/// 2. **Les durées calées sur le matériel** — la rafale de bascule d'objectif
///    (520 ms) couvre le temps mort de réouverture de la caméra. Elle suit le
///    capteur, pas l'esthétique.
/// 3. **Les moments de révélation** — le flou qui se dissipe sur une Vibe
///    révélée (1600 ms) est un **contenu**, pas de l'habillage. Il dure
///    longtemps exprès.
abstract final class NeoMotion {
  /// Rien ne se déplace — opacité, couleur, bascule, retour d'appui.
  ///
  /// Assez court pour être ressenti comme instantané tout en évitant le
  /// clignotement d'un changement sec.
  static const fast = Duration(milliseconds: 120);

  /// Déplacement local — un menu qui se déplie, un bandeau qui descend, un
  /// élément qui prend sa place.
  static const normal = Duration(milliseconds: 220);

  /// Déplacement plein écran — navigation, retournement d'une Vibe.
  static const ample = Duration(milliseconds: 380);

  /// Ce qui **arrive** : rapide au départ, ralenti à l'arrivée. C'est la courbe
  /// par défaut ; dans le doute, c'est celle-là.
  static const enter = Curves.easeOutCubic;

  /// Ce qui **part** : lent au départ, accéléré vers la sortie. Symétrique de
  /// [enter], et réservée aux disparitions — l'utiliser sur une apparition
  /// donne un mouvement qui démarre mou.
  static const exit = Curves.easeInCubic;

  /// Le **ressort**, réservé à ce que le doigt vient de toucher.
  ///
  /// Il dépasse légèrement sa cible avant de revenir : c'est ce dépassement qui
  /// fait « matière » plutôt que « glissière ». À garder rare — partout, il
  /// donne une app qui tremble.
  static const spring = Curves.easeOutBack;
}

/// Transition de page de l'app, branchée sur [NeoMotion].
///
/// ## Le point important : **une seule ligne pilote 46 navigations**
///
/// `MaterialRouteTransitionMixin.transitionDuration` lit la durée du
/// `PageTransitionsBuilder` du thème (vérifié dans le SDK,
/// `material/page.dart:91`). Poser ce constructeur dans `NeoTheme` change donc
/// **toutes** les navigations de l'app sans toucher un seul appel à
/// `MaterialPageRoute` — 46 sites répartis dans 23 fichiers.
///
/// C'est ce qui rend ce chantier tenable : le mouvement est une propriété de
/// l'app, pas une décision reprise à chaque `Navigator.push`.
///
/// ## Ce que la transition fait
///
/// Un glissement **court** (6 % de la largeur) plus un fondu, et la page qui
/// part recule d'un peu moins. Volontairement sobre : une transition de page se
/// voit des dizaines de fois par session, c'est le pire endroit où être
/// démonstratif.
class NeoPageTransitionsBuilder extends PageTransitionsBuilder {
  const NeoPageTransitionsBuilder();

  @override
  Duration get transitionDuration => NeoMotion.ample;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // `CurveTween(...).animate(...)` plutôt que `CurvedAnimation` : ce dernier
    // s'abonne à son parent et doit être libéré. Construit dans un `build`, il
    // fuirait. Le tween, lui, ne retient rien.
    final incoming = Tween(
      begin: const Offset(0.06, 0),
      end: Offset.zero,
    ).chain(CurveTween(curve: NeoMotion.enter)).animate(animation);
    final outgoing = Tween(
      begin: Offset.zero,
      end: const Offset(-0.03, 0),
    ).chain(CurveTween(curve: NeoMotion.enter)).animate(secondaryAnimation);
    final fade = CurveTween(curve: NeoMotion.enter).animate(animation);

    return SlideTransition(
      position: outgoing,
      child: SlideTransition(
        position: incoming,
        child: FadeTransition(opacity: fade, child: child),
      ),
    );
  }
}
