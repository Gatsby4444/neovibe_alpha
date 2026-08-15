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

  /// Le **pas d'une séquence de construction** : le temps entre deux éléments
  /// qui s'installent l'un après l'autre.
  ///
  /// Une seule valeur pour toute l'app — demande de Jay, 2026-08-15 : *« pour
  /// l'apparition des boutons de la navbar mets le même intervalle que pour
  /// les boutons latéraux de l'interface caméra »*. Le rail de la capture
  /// l'utilisait déjà ; la barre de navigation s'y aligne.
  ///
  /// ⚠️ C'est ce qui a forcé à **détacher la barre de l'animation de route** :
  /// cinq icônes à 63 ms ne tiennent pas dans les 380 ms d'une navigation. Le
  /// pas est une propriété du rythme, pas de la durée du conteneur — donc
  /// c'est le conteneur qui devait céder.
  static const buildStepMs = 63;
  static const buildStep = Duration(milliseconds: buildStepMs);

  /// Le temps que met UN élément à s'installer, une fois son tour venu.
  static const buildItemMs = 260;
  static const buildItem = Duration(milliseconds: buildItemMs);

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
/// Un glissement **court** (6 % de la largeur) plus un **relais de fondu** : la
/// page qui part s'efface pendant la première moitié, celle qui arrive
/// apparaît pendant la seconde. Volontairement sobre : une transition de page
/// se voit des dizaines de fois par session, c'est le pire endroit où être
/// démonstratif.
///
/// ## 🐛 Le défaut corrigé le 2026-08-15, et ce qu'il apprend
///
/// La première version ne faisait **que** le fondu d'entrée : la page qui part
/// glissait de 3 % mais **restait à pleine opacité** jusqu'au bout. Puis
/// Flutter cessait simplement de la peindre — une `MaterialPageRoute` est
/// `opaque`, donc la route du dessous est retirée de l'arbre à `t = 1`.
///
/// Tant que les pages étaient **opaques**, rien ne se voyait : la nouvelle
/// recouvrait l'ancienne. Le thème NeoVibe a rendu les `Scaffold`
/// transparents — et a donc **retiré ce qui cachait la couture**, sans rien
/// casser lui-même. Symptôme rapporté par Jay : *« l'écran suivant apparaît
/// d'un coup, puis le précédent disparaît d'un coup »*. Les deux « d'un coup »
/// sont ce même défaut, vu dans les deux sens.
///
/// **Leçon générale** : un fond opaque est un *masque*. Tout ce qu'on règle
/// derrière lui est réglé à l'aveugle, et le jour où on le retire, ce n'est pas
/// une régression qui apparaît — c'est un défaut qui devient visible.
///
/// Second point, plus discret : le fondu suivait `easeOutCubic` sur **toute**
/// la durée, donc 70 % du changement se produisait dans le premier tiers. D'où
/// *« l'animation est en fait un tout petit bout de la transition »*. Les
/// intervalles ci-dessous règlent ça aussi.
class NeoPageTransitionsBuilder extends PageTransitionsBuilder {
  const NeoPageTransitionsBuilder();

  /// Le relais : la page qui part a disparu à 45 % du chemin, celle qui arrive
  /// commence à 25 %. Ils se croisent donc sur 20 % — assez pour qu'il n'y ait
  /// jamais de trou, trop peu pour qu'on lise une double exposition.
  ///
  /// ⚠️ Ne pas supprimer le recouvrement en croyant « nettoyer » : sans lui,
  /// l'écran serait vide pendant un instant, et sur le dégradé du thème
  /// NeoVibe ce vide se verrait parfaitement.
  static const _outEnd = 0.45;
  static const _inStart = 0.25;

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

    final fadeIn = CurveTween(
      curve: const Interval(_inStart, 1, curve: NeoMotion.enter),
    ).animate(animation);

    // Le fondu de SORTIE, celui qui manquait. Piloté par `secondaryAnimation`,
    // donc il vaut aussi bien pour la page recouverte (push) que pour la page
    // révélée (pop) : au retour, elle réapparaît pendant la seconde moitié au
    // lieu de surgir à pleine opacité.
    final fadeOut = Tween(begin: 1.0, end: 0.0)
        .chain(
          CurveTween(curve: const Interval(0, _outEnd, curve: NeoMotion.exit)),
        )
        .animate(secondaryAnimation);

    return SlideTransition(
      position: outgoing,
      child: FadeTransition(
        opacity: fadeOut,
        child: SlideTransition(
          position: incoming,
          child: FadeTransition(opacity: fadeIn, child: child),
        ),
      ),
    );
  }
}

/// Un élément d'une **séquence de construction** : il s'installe à son tour,
/// après ceux qui le précèdent.
///
/// ## Pourquoi un contrôleur, et non l'animation de la route
///
/// La version précédente lisait l'animation de la route. C'était plus court à
/// écrire, mais ça enfermait toute la séquence dans les 380 ms d'une
/// navigation — or cinq éléments à [NeoMotion.buildStep] en réclament déjà
/// 252 rien qu'en décalages, avant même que le dernier ait commencé.
///
/// Deux défauts en découlaient, tous deux constatés :
///
/// 1. **Le pas était plafonné par la durée de la navigation.** Jay : *« ce
///    n'est pas vraiment perceptible l'apparition progressive »*.
/// 2. **Une enveloppe de groupe multipliait les opacités.** Chaque élément
///    était borné par la porte commune, ce qui écrasait l'échelonnement au
///    démarrage — précisément l'effet qu'on cherchait à produire.
///
/// Piloté par un contrôleur propre, le rythme ne dépend plus de ce qui se
/// passe autour.
class NeoBuildIn extends StatelessWidget {
  const NeoBuildIn({
    super.key,
    required this.animation,
    required this.index,
    required this.total,
    this.rise = 14,
    required this.child,
  });

  /// Le contrôleur de la séquence. Sa durée doit valoir [durationFor].
  final Animation<double> animation;

  /// Rang dans la séquence, à partir de 0.
  final int index;

  /// Nombre d'éléments — sert à calculer les fractions.
  final int total;

  /// De combien l'élément monte en arrivant, en pixels.
  final double rise;

  final Widget child;

  /// La durée qu'un contrôleur doit avoir pour porter [count] éléments.
  static Duration durationFor(int count) => Duration(
    milliseconds:
        (count - 1).clamp(0, 99) * NeoMotion.buildStep.inMilliseconds +
        NeoMotion.buildItem.inMilliseconds,
  );

  @override
  Widget build(BuildContext context) {
    final totalMs = durationFor(total).inMilliseconds;
    final beginMs = index * NeoMotion.buildStep.inMilliseconds;
    final begin = (beginMs / totalMs).clamp(0.0, 1.0);
    final end = ((beginMs + NeoMotion.buildItem.inMilliseconds) / totalMs)
        .clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, inner) {
        final t = Interval(
          begin,
          end == begin ? 1.0 : end,
          curve: NeoMotion.enter,
        ).transform(animation.value.clamp(0.0, 1.0));
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * rise),
            child: inner,
          ),
        );
      },
    );
  }
}

/// Ouverture en **fondu pur** : aucun glissement, ni pour la page qui arrive ni
/// pour celle qui part.
///
/// ## Pourquoi une route à part, et pas un réglage du thème
///
/// La transition de l'app ([NeoPageTransitionsBuilder]) glisse de 6 % : c'est
/// juste pour une navigation *dans* une hiérarchie — on va « vers la droite ».
///
/// L'écran de capture n'est pas une page de plus dans une hiérarchie : c'est un
/// **mode**, qui prend l'appareil photo et l'écran entier. Jay au test de la
/// v0.9.87 : *« il y a un mouvement saccadé non désiré à l'ouverture, comme si
/// l'interface actuelle se décalait vers la gauche et que l'interface caméra
/// apparaissait en venant de la droite. Je veux que tu supprimes cela, et
/// remplaces par un fondu progressif. Propre et fluide, sans parasites. »*
///
/// Le glissement n'était pas un bug — c'était la transition générale appliquée
/// à un écran qui n'en relève pas. Un mode n'arrive pas *d'un côté*.
///
/// ⚠️ **Ne pas généraliser** : appliqué partout, on perdrait le sens de la
/// direction, et revenir en arrière ressemblerait à avancer.
class NeoFadeRoute<T> extends PageRouteBuilder<T> {
  NeoFadeRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: NeoMotion.ample,
        reverseTransitionDuration: NeoMotion.ample,
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) =>
            FadeTransition(
              opacity: CurveTween(curve: NeoMotion.enter).animate(animation),
              child: child,
            ),
      );
}
