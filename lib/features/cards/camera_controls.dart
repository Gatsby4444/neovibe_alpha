/// Les contrôles de l'écran de capture.
///
/// ## La direction, tranchée par Jay le 2026-08-14
///
/// Quatre directions lui ont été proposées (v0.9.80). Son choix :
///
/// > « Les boutons sans contours, uniquement le logo, pas de fond non plus,
/// > uniquement l'icône du bouton, on les resserre un peu et on les met tels
/// > quels. Et lorsqu'ils sont en état sélectionné on les met en surbrillance
/// > de couleur mais uniquement les icônes. C'est le plus épuré possible je
/// > pense. »
///
/// **Les trois autres directions ont été supprimées**, ainsi que le sélecteur
/// des réglages. Garder des variantes non retenues, c'est garder du code que
/// personne ne relit et que le premier changement d'API cassera en silence.
///
/// ## Ce qui reste, et pourquoi
///
/// Aucun fond, aucun anneau, aucun rail : **l'icône seule**. C'est la version
/// la plus épurée possible — et sur un écran caméra, c'est aussi la plus
/// juste : l'image est le sujet, rien ne doit la masquer.
///
/// **L'ombre portée n'est pas un fond.** Sans elle, une icône blanche disparaît
/// sur un ciel, un mur clair ou une feuille de papier — c'est-à-dire dans les
/// cas les plus courants d'une app photo. Elle ne se voit pas ; elle empêche
/// simplement l'icône de s'effacer. C'est le seul artifice conservé, et il sert
/// la lisibilité, pas le décor.
///
/// **L'état actif ne colore que l'icône** (rose de marque), conformément à la
/// convention du projet : la couleur ne signale qu'une chose, ce qui est actif.
library;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// Mesures des contrôles.
abstract final class _Dim {
  /// Zone tactile. Reste à 44 même si l'icône est plus petite : c'est le
  /// plancher confortable pour le pouce, et sans fond rien ne signale au doigt
  /// où appuyer — la zone doit donc être généreuse, pas serrée sur le dessin.
  static const touch = 44.0;

  static const icon = 23.0;

  /// « On les resserre un peu » (Jay). 14 → 8 : sans disque autour d'elles,
  /// les icônes ont besoin de moins d'air pour se lire comme distinctes.
  static const spacing = 8.0;
}

/// La colonne de contrôles à droite de l'aperçu.
///
/// Elle ne pose plus aucun fond : ce n'est qu'un empilement. Elle existe encore
/// pour deux raisons — l'écartement, et l'entrée décalée de ses enfants.
class CameraRail extends StatelessWidget {
  const CameraRail({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: _Dim.spacing),
          _Entry(index: i, child: children[i]),
        ],
      ],
    );
  }
}

/// Un contrôle : une icône, et rien d'autre.
///
/// Même API que l'`IconButton.filledTonal` qu'il a remplacé — `icon`,
/// `tooltip`, `onPressed` — pour que l'habillage ne touche à rien de ce que les
/// boutons **commandent**.
class CameraButton extends StatefulWidget {
  const CameraButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.onLongPress,
    this.active = false,
    this.underlay,
  });

  final Widget icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// Actif : l'icône passe en rose de marque. **Rien d'autre ne change** —
  /// consigne de Jay, « uniquement les icônes ».
  final bool active;

  /// Peint sous l'icône, dans un disque — la pastille de couleur du bouton de
  /// fond de face. Seul contrôle à en avoir un : sa couleur EST son icône.
  final Widget? underlay;

  @override
  State<CameraButton> createState() => _CameraButtonState();
}

class _CameraButtonState extends State<CameraButton>
    with SingleTickerProviderStateMixin {
  // Le système de mouvement (`core/motion.dart`) : appui sec, relâchement plus
  // ample avec un ressort.
  late final _press = AnimationController(
    vsync: this,
    duration: NeoMotion.fast,
    reverseDuration: NeoMotion.normal,
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onPressed != null || widget.onLongPress != null;

  @override
  Widget build(BuildContext context) {
    final color = widget.active
        ? context.darkPalette.action
        : Colors.white.withValues(alpha: _enabled ? 1 : 0.38);

    // Sans fond, l'appui n'a rien à assombrir : le seul retour possible est le
    // mouvement de l'icône elle-même. Il est donc un peu plus marqué qu'avant
    // (0,86 contre 0,91) — sinon le geste ne se sentirait pas.
    const shadows = [Shadow(color: Color(0x99000000), blurRadius: 6)];

    // La zone de clic est EXACTEMENT la boîte de 44 : l'échelle est appliquée
    // SOUS le détecteur de gestes, jamais au-dessus (leçon du bouton d'envoi —
    // un contrôle mis à l'échelle a deux boîtes, et si elles diffèrent, la
    // règle « relâcher hors de la zone annule » devient vraie partout).
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _press.forward() : null,
      onTapUp: _enabled ? (_) => _press.reverse() : null,
      onTapCancel: _enabled ? () => _press.reverse() : null,
      onTap: widget.onPressed,
      onLongPress: widget.onLongPress,
      child: SizedBox(
        width: _Dim.touch,
        height: _Dim.touch,
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, child) {
            final t = _press.status == AnimationStatus.reverse
                ? NeoMotion.spring.transform(_press.value)
                : NeoMotion.enter.transform(_press.value);
            return Transform.scale(scale: 1 - 0.14 * t, child: child);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.underlay != null)
                Padding(
                  padding: const EdgeInsets.all(6),
                  // Contour blanc fin (demande de Jay, 2026-08-15) : « dans le
                  // noir, le bouton s'il est noir est difficilement visible ».
                  //
                  // C'est le même raisonnement que l'ombre portée des icônes,
                  // appliqué à un contrôle dont la couleur EST le contenu : on
                  // ne peut pas l'assombrir pour le détacher, puisque c'est
                  // elle qu'on montre. Il lui faut donc une bordure.
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                      boxShadow: const [
                        BoxShadow(color: Color(0x99000000), blurRadius: 6),
                      ],
                    ),
                    child: ClipOval(child: widget.underlay),
                  ),
                ),
              Center(
                child: IconTheme.merge(
                  data: IconThemeData(
                    size: _Dim.icon,
                    color: color,
                    shadows: shadows,
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: color,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: shadows,
                    ),
                    child: widget.icon,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip == null) return button;
    return Tooltip(
      message: tooltip,
      // Sur mobile une infobulle se déclenche à l'APPUI LONG — le même geste
      // que la palette du bouton de couleur. Quand le bouton a sa propre
      // action d'appui long, c'est elle qui gagne.
      triggerMode: widget.onLongPress != null
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: button,
    );
  }
}

/// Porte l'animation d'**entrée de l'écran de capture** jusqu'aux contrôles.
///
/// ## 🐛 Le défaut que ça corrige (2026-08-15)
///
/// Le décalage des contrôles existait déjà depuis la v0.9.80 — mais chaque
/// contrôle démarrait son propre minuteur **au moment où il était construit**,
/// c'est-à-dire à l'ouverture de l'écran, **pendant que l'aperçu est encore
/// noir**. La vague était donc entièrement consommée avant que l'image
/// n'arrive : quand la caméra s'ouvrait enfin, tout était déjà en place.
///
/// D'où le constat de Jay : *« toute l'interface s'affiche d'un coup sans
/// transition ni fondu »*. L'animation existait ; **elle jouait devant un
/// écran noir**.
///
/// **Leçon** : une animation d'entrée ne se déclenche pas à la construction du
/// widget, mais au moment où **ce qu'elle accompagne devient visible**. Les
/// deux coïncident presque toujours — et c'est précisément pourquoi le cas où
/// ils divergent passe inaperçu.
///
/// La séquence est maintenant pilotée d'un seul endroit
/// (`card_capture_screen.dart`), déclenchée sur `_previewReady`.
class CameraEntrance extends InheritedWidget {
  const CameraEntrance({
    super.key,
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  /// Durée de la séquence complète.
  ///
  /// Elle vit **ici** et non dans l'écran de capture : c'est la séquence qui
  /// distribue le rythme à ses éléments, et les fractions ci-dessous en
  /// dépendent. La séparer de son propre calcul les ferait diverger en
  /// silence.
  static const durationMs = 900;
  static const duration = Duration(milliseconds: durationMs);

  /// `null` hors de l'écran de capture — les contrôles s'affichent alors sans
  /// animation plutôt que de rester invisibles.
  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CameraEntrance>()?.animation;

  @override
  bool updateShouldNotify(CameraEntrance oldWidget) =>
      oldWidget.animation != animation;
}

/// Le déclencheur central — il entre **avant** les options latérales.
///
/// Consigne de Jay : *« une animation qui affiche l'apparition du bouton
/// central de prise puis progressivement les boutons d'options latéraux »*.
/// C'est aussi l'ordre juste : le déclencheur est ce qu'on est venu chercher,
/// les options sont ce qu'on consultera peut-être.
class CameraShutterEntrance extends StatelessWidget {
  const CameraShutterEntrance({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final entrance = CameraEntrance.maybeOf(context);
    if (entrance == null) return child;

    return AnimatedBuilder(
      animation: entrance,
      // ⚠️ `child` passé ici et JAMAIS reconstruit dans le builder : le
      // déclencheur porte un `RawGestureDetector` dont les reconnaisseurs sont
      // détruits si le sous-arbre est rebâti. C'est exactement la panne du
      // 2026-07-14 (relâcher n'arrêtait plus la vidéo), et elle ne lève
      // aucune erreur.
      child: child,
      builder: (context, inner) {
        final t = const Interval(
          0.20,
          0.65,
          curve: NeoMotion.spring,
        ).transform(entrance.value);
        return Opacity(
          // Le ressort dépasse 1 : l'opacité, elle, ne le peut pas.
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.86 + 0.14 * t, child: inner),
        );
      },
    );
  }
}

/// Entrée décalée : chaque contrôle arrive après le précédent.
///
/// Le rail entre **après** le déclencheur, et ses icônes une par une.
class _Entry extends StatelessWidget {
  const _Entry({required this.index, required this.child});

  /// Part de la séquence écoulée avant que le rail ne commence — après le
  /// déclencheur, qui est ce qu'on est venu chercher.
  static const _railStart = 0.42;

  /// Le pas de construction de l'app ([NeoMotion.buildStep], 63 ms), exprimé
  /// en fraction de la séquence de l'écran de capture.
  ///
  /// ⚠️ **Dérivé, jamais recopié** : c'est le même rythme que la barre de
  /// navigation depuis le 2026-08-15 (demande de Jay). Écrire 0,07 en dur ici
  /// laisserait les deux diverger à la première retouche, sans que rien ne le
  /// signale.
  static const _step = NeoMotion.buildStepMs / CameraEntrance.durationMs;

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final entrance = CameraEntrance.maybeOf(context);
    if (entrance == null) return child;

    return AnimatedBuilder(
      animation: entrance,
      child: child,
      builder: (context, inner) {
        final t = Interval(
          (_railStart + index * _step).clamp(0.0, 0.9),
          1,
          curve: NeoMotion.enter,
        ).transform(entrance.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - t)),
            child: inner,
          ),
        );
      },
    );
  }
}
