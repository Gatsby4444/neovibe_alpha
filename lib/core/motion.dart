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

/// Fait entrer un élément **après** le reste de sa page, et sortir **avant**.
///
/// ## Pourquoi ça existe
///
/// Demande de Jay, 2026-08-15 : *« la fluidité, le premium […] si on revient
/// sur l'écran principal, la barre du bas apparaît via une animation séparée
/// 200-300 ms plus tard. »*
///
/// Une page qui apparaît d'un bloc se lit comme une **image** qu'on remplace.
/// Les mêmes éléments décalés de quelques dixièmes se lisent comme un
/// **espace** qui se recompose — c'est toute la différence, et elle ne coûte
/// que du décalage.
///
/// ## Ce qu'il faut savoir avant de s'en servir
///
/// 1. **Il se multiplie avec le fondu de la page**, il ne le remplace pas. Un
///    élément enveloppé ici est donc *deux fois* plus lent à apparaître que le
///    reste — c'est l'effet voulu, mais c'est pourquoi il doit rester **rare**.
///    Partout, il donnerait une app qui traîne.
/// 2. **Réservé à la structure** : barre de navigation, en-tête. Pas au
///    contenu — décaler ce qu'on est venu lire, c'est faire attendre.
/// 3. Hors d'une route (test, aperçu), il est **neutre** : pas d'animation,
///    pas d'erreur.
class NeoStagger extends StatelessWidget {
  const NeoStagger({
    super.key,
    required this.child,
    this.delay = 0.45,
    this.lead = 0.22,
    this.rise = 14,
  });

  final Widget child;

  /// Part de la transition écoulée avant que l'élément ne commence à entrer,
  /// quand c'est **lui** la page qui arrive.
  final double delay;

  /// Symétrique, pour l'autre sens : l'élément a **fini** de partir à cette
  /// fraction, quand sa page se fait recouvrir.
  ///
  /// ⚠️ **Doit rester inférieur au `_outEnd` de [NeoPageTransitionsBuilder]**
  /// (0,45), et c'est la seule chose à vérifier en y touchant. C'est lui qui
  /// porte l'effet au **retour** : la page réapparaît quand son recouvrement
  /// repasse sous 0,45, l'élément seulement sous 0,22 — donc **après**.
  ///
  /// 🐛 Ma première version dérivait cette valeur de [delay] (`1 - delay`,
  /// soit 0,55). Elle était donc **supérieure** à 0,45, et la barre
  /// réapparaissait *avant* le contenu — l'inverse exact de ce qui était
  /// demandé. Deux réglages opposés ne se déduisent pas l'un de l'autre par
  /// symétrie : ils se nomment.
  final double lead;

  /// De combien l'élément monte en arrivant, en pixels. Un bas de page vient
  /// donc du bas — la direction dit d'où l'élément appartient.
  final double rise;

  /// Le décalage d'un cran à l'autre d'une **vague** — voir [wave].
  static const waveStep = 0.06;

  /// Un élément d'une vague : le même mouvement, retardé d'un cran par rang.
  ///
  /// Demande de Jay, 2026-08-15 : *« l'animation d'apparition qui démarre pour
  /// chaque bouton de la navbar avec un léger décalage »*.
  ///
  /// ⚠️ Le pas est **petit exprès**. Une vague se lit à partir d'environ 40 ms
  /// entre voisins ; au-delà de ~100 ms elle cesse d'être un mouvement d'
  /// ensemble et devient cinq apparitions qu'on attend l'une après l'autre.
  /// Sur les 380 ms du palier [NeoMotion.ample], 0,06 ≈ **23 ms par cran** —
  /// et cinq boutons tiennent donc dans 90 ms.
  factory NeoStagger.wave({
    Key? key,
    required int index,
    required Widget child,
    double delay = 0.45,
    double rise = 14,
  }) => NeoStagger(
    key: key,
    delay: delay + index * waveStep,
    // Le départ, lui, n'est PAS décalé : à la sortie, une vague inversée
    // donnerait l'impression que la barre s'effiloche. On part ensemble.
    lead: 0.22,
    rise: rise,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final enter = route?.animation;
    final cover = route?.secondaryAnimation;
    if (enter == null || cover == null) return child;

    return AnimatedBuilder(
      animation: Listenable.merge([enter, cover]),
      child: child,
      builder: (context, inner) {
        // Entre en retard…
        final arriving = Interval(
          // Borné : une vague de beaucoup d'éléments pousserait sinon le
          // dernier au-delà de 1, et `Interval` lèverait une assertion.
          delay.clamp(0.0, 0.9),
          1,
          curve: NeoMotion.enter,
        ).transform(enter.value.clamp(0.0, 1.0));

        // …et sort en avance, sinon l'élément partirait en même temps que le
        // reste et le décalage ne se verrait qu'à l'aller.
        final leaving = Interval(
          0,
          lead,
          curve: NeoMotion.exit,
        ).transform(cover.value.clamp(0.0, 1.0));

        final t = (arriving * (1 - leaving)).clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          // `Transform.translate` et non un `SlideTransition` : on veut des
          // pixels, pas une fraction de la taille de l'élément — une barre de
          // navigation et un en-tête n'ont pas la même hauteur, et devraient
          // pourtant parcourir la même distance.
          child: Transform.translate(
            offset: Offset(0, (1 - t) * rise),
            child: inner,
          ),
        );
      },
    );
  }
}
