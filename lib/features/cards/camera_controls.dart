/// Les contrôles de l'écran de capture, en **quatre directions artistiques**
/// interchangeables.
///
/// Consigne de Jay, 2026-08-14 : « il faut redesigner les boutons de
/// l'interface caméra. Je ne te donne qu'une directive, le thème à la Apple.
/// Je te laisse libre de proposer d'autres styles […] tu peux coder plusieurs
/// DA et je les teste toutes en switchant dans les paramètres. »
///
/// ## Ce que « à la Apple » veut dire ici
///
/// Pas un matériau précis — une **discipline**. Rien qui ne serve à quelque
/// chose, une hiérarchie tenue par le contraste et l'espacement plutôt que par
/// la couleur, et des contrôles qui s'effacent devant le contenu. Sur un écran
/// caméra, ça se traduit par une règle simple : **l'image est le sujet, les
/// boutons sont des outils.** Les quatre directions ci-dessous appliquent cette
/// discipline avec quatre matériaux différents ; aucune n'ajoute d'ornement.
///
/// ⚠️ Le **liquid glass a été écarté** par Jay le 2026-08-14 (archivé dans
/// `archives/liquid-glass-2026-08-14/`). Aucune de ces directions ne le
/// reprend : [CameraButtonStyle.matiere] est du **verre dépoli** — un flou et
/// une teinte, pas une lentille — ce qui est un tout autre registre.
///
/// ## Le mouvement n'est PAS un axe de choix
///
/// Les quatre partagent le même système (`core/motion.dart`) : appui en
/// [NeoMotion.fast], relâchement en [NeoMotion.normal] avec [NeoMotion.spring].
/// Ce qui change d'une direction à l'autre, c'est **la matière**, jamais le
/// tempo — sinon on comparerait deux choses à la fois et le test ne dirait
/// rien.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// Les quatre directions proposées à Jay.
///
/// ⚠️ Stockées par leur **indice** dans les préférences : ne jamais réordonner
/// sans migration, un appareil déjà installé relirait l'ancien indice.
enum CameraButtonStyle {
  /// **Sobre** — aucun rail, des disques translucides sombres, icône blanche
  /// fine. Le registre de l'app Appareil photo d'iOS : les contrôles flottent
  /// sur l'image et ne lui volent rien.
  sobre,

  /// **Matière** — un rail en verre dépoli clair, icônes sombres. Le registre
  /// du centre de contrôle d'iOS. La seule direction qui **floute** l'aperçu,
  /// donc la seule qui coûte quelque chose à l'affichage.
  matiere,

  /// **Contour** — aucun fond, seulement un anneau fin autour de chaque icône.
  /// La plus légère et la plus « appareil photo » : rien ne masque l'image.
  contour,

  /// **Plein** — un rail sombre opaque, disques nets, icônes blanches. Zéro
  /// flou, lisibilité maximale, coût d'affichage nul. Le repli sûr.
  plein;

  String get label => switch (this) {
    CameraButtonStyle.sobre => 'Sobre',
    CameraButtonStyle.matiere => 'Matière',
    CameraButtonStyle.contour => 'Contour',
    CameraButtonStyle.plein => 'Plein',
  };

  String get description => switch (this) {
    CameraButtonStyle.sobre =>
      'Disques translucides sombres, sans rail. Les contrôles flottent sur '
          'l\'image.',
    CameraButtonStyle.matiere =>
      'Rail en verre dépoli clair, icônes sombres. La seule qui floute '
          'l\'aperçu — si la caméra saccade, c\'est celle-ci.',
    CameraButtonStyle.contour =>
      'Un simple anneau autour de chaque icône. Rien ne masque l\'image.',
    CameraButtonStyle.plein =>
      'Rail sombre opaque. Lisibilité maximale, aucun coût d\'affichage.',
  };
}

/// Mesures communes. Identiques d'une direction à l'autre : c'est ce qui rend
/// la comparaison honnête — seule la matière change.
abstract final class _Dim {
  static const button = 50.0;
  static const icon = 21.0;
  static const railRadius = 30.0;

  /// L'écartement suit la direction : sans rail il faut plus d'air pour que
  /// les disques se lisent comme des objets distincts ; dans un rail, moins,
  /// sinon le rail s'allonge sans raison.
  static double spacingFor(CameraButtonStyle style) => switch (style) {
    CameraButtonStyle.sobre => 14,
    CameraButtonStyle.contour => 16,
    CameraButtonStyle.matiere => 8,
    CameraButtonStyle.plein => 8,
  };
}

/// Porte la direction courante jusqu'aux boutons.
class _StyleScope extends InheritedWidget {
  const _StyleScope({required this.style, required super.child});

  final CameraButtonStyle style;

  static CameraButtonStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_StyleScope>()?.style ??
      CameraButtonStyle.sobre;

  @override
  bool updateShouldNotify(_StyleScope old) => old.style != style;
}

/// La colonne de contrôles à droite de l'aperçu.
///
/// Selon la direction, elle pose un rail derrière ses enfants ou les laisse
/// flotter. Les enfants sont **toujours** posés hors du découpage : les menus
/// qui s'ouvrent vers la gauche (flash, retardateur) débordent donc du rail au
/// lieu d'être coupés.
class CameraRail extends StatelessWidget {
  const CameraRail({super.key, required this.children, required this.style});

  final List<Widget> children;
  final CameraButtonStyle style;

  bool get _hasRail =>
      style == CameraButtonStyle.matiere || style == CameraButtonStyle.plein;

  double get _railWidth => _Dim.button + 12;

  double get _railHeight =>
      children.length * _Dim.button +
      (children.length - 1) * _Dim.spacingFor(style) +
      16;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: _Dim.spacingFor(style)),
          _Entry(index: i, child: children[i]),
        ],
      ],
    );

    if (!_hasRail) return _StyleScope(style: style, child: column);

    return _StyleScope(
      style: style,
      // `Clip.none` + alignement à droite : le rail garde sa largeur, la
      // colonne peut être plus large quand un menu s'ouvre, et ce surplus
      // déborde vers la gauche sans être coupé.
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerRight,
        children: [
          // `RepaintBoundary` : l'aperçu caméra repeint en continu dessous.
          RepaintBoundary(
            child: SizedBox(
              width: _railWidth,
              height: _railHeight,
              child: _rail(),
            ),
          ),
          column,
        ],
      ),
    );
  }

  Widget _rail() {
    final shape = BorderRadius.circular(_Dim.railRadius);
    if (style == CameraButtonStyle.plein) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: NeoNeutrals.gray900.withValues(alpha: 0.92),
          borderRadius: shape,
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
      );
    }
    // Matière : le seul `BackdropFilter` de tout ce fichier.
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.30),
                Colors.white.withValues(alpha: 0.16),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.38)),
            borderRadius: shape,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Un contrôle du rail.
///
/// Même API que l'`IconButton.filledTonal` qu'il remplace — `icon`, `tooltip`,
/// `onPressed` — pour que le changement de direction ne touche à rien de ce que
/// les boutons **commandent**.
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

  /// État « armé ». Convention du projet : le rose ne signale qu'une chose,
  /// ce qui est actif.
  final bool active;

  /// Peint **sous** le bouton, dans le disque — la pastille de couleur du
  /// bouton de fond de face.
  final Widget? underlay;

  @override
  State<CameraButton> createState() => _CameraButtonState();
}

class _CameraButtonState extends State<CameraButton>
    with SingleTickerProviderStateMixin {
  // Le système de mouvement, pas des valeurs choisies ici : appui sec,
  // relâchement plus ample avec un ressort. Identique dans les quatre
  // directions — on compare des matières, pas des tempos.
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

  /// Les icônes sont **sombres** sur la matière claire, **blanches** partout
  /// ailleurs. C'est la seule chose qui change vraiment pour l'œil.
  bool _darkIcons(CameraButtonStyle style) =>
      style == CameraButtonStyle.matiere;

  @override
  Widget build(BuildContext context) {
    final style = _StyleScope.of(context);
    final dark = _darkIcons(style);
    final base = dark ? const Color(0xFF16161A) : Colors.white;
    final iconColor = widget.active
        ? NeoTheme.accentPink
        : base.withValues(alpha: _enabled ? 1 : 0.38);

    // La zone de clic est EXACTEMENT le disque visible : l'échelle est
    // appliquée SOUS le détecteur de gestes, jamais au-dessus (leçon du bouton
    // d'envoi — un contrôle mis à l'échelle a deux boîtes).
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _press.forward() : null,
      onTapUp: _enabled ? (_) => _press.reverse() : null,
      onTapCancel: _enabled ? () => _press.reverse() : null,
      onTap: widget.onPressed,
      onLongPress: widget.onLongPress,
      child: SizedBox(
        width: _Dim.button,
        height: _Dim.button,
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, child) {
            final t = _press.status == AnimationStatus.reverse
                ? NeoMotion.spring.transform(_press.value)
                : NeoMotion.enter.transform(_press.value);
            return Transform.scale(
              scale: 1 - 0.09 * t,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.underlay != null) ClipOval(child: widget.underlay),
                  CustomPaint(
                    painter: _ButtonPainter(
                      style: style,
                      pressed: t.clamp(0.0, 1.0),
                      active: widget.active,
                      enabled: _enabled,
                    ),
                    child: child,
                  ),
                ],
              ),
            );
          },
          child: Center(
            child: IconTheme.merge(
              data: IconThemeData(
                size: _Dim.icon,
                color: iconColor,
                // Sans rail, l'icône se pose directement sur l'image : une
                // ombre portée est ce qui la garde lisible sur un ciel blanc.
                shadows: style == CameraButtonStyle.matiere
                    ? null
                    : const [Shadow(color: Color(0x8C000000), blurRadius: 5)],
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: iconColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  shadows: style == CameraButtonStyle.matiere
                      ? null
                      : const [Shadow(color: Color(0x8C000000), blurRadius: 5)],
                ),
                child: widget.icon,
              ),
            ),
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

/// Ce qui se peint derrière l'icône, direction par direction.
class _ButtonPainter extends CustomPainter {
  const _ButtonPainter({
    required this.style,
    required this.pressed,
    required this.active,
    required this.enabled,
  });

  final CameraButtonStyle style;
  final double pressed;
  final bool active;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final o = enabled ? 1.0 : 0.45;

    switch (style) {
      // Disque translucide sombre + liseré d'un cheveu. L'appui l'assombrit :
      // le bouton s'enfonce dans l'image au lieu de s'en détacher.
      case CameraButtonStyle.sobre:
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..color = Colors.black.withValues(
              alpha: (0.30 + 0.16 * pressed) * o,
            ),
        );
        canvas.drawCircle(
          center,
          r - 0.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = (active ? NeoTheme.accentPink : Colors.white).withValues(
              alpha: (active ? 0.85 : 0.24) * o,
            ),
        );

      // Rien : le rail dépoli porte tout. L'appui pose un voile sombre, seul
      // retour visuel dont on dispose sans salir la matière.
      case CameraButtonStyle.matiere:
        if (pressed > 0) {
          canvas.drawCircle(
            center,
            r,
            Paint()..color = Colors.black.withValues(alpha: 0.14 * pressed),
          );
        }
        if (active) {
          canvas.drawCircle(
            center,
            r - 1,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = NeoTheme.accentPink.withValues(alpha: 0.85 * o),
          );
        }

      // Un anneau, rien d'autre. L'appui l'épaissit et pose un voile clair —
      // la seule direction où l'image reste visible DANS le bouton.
      case CameraButtonStyle.contour:
        if (pressed > 0) {
          canvas.drawCircle(
            center,
            r,
            Paint()..color = Colors.white.withValues(alpha: 0.16 * pressed),
          );
        }
        canvas.drawCircle(
          center,
          r - 1,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6 + 1.0 * pressed
            ..color = (active ? NeoTheme.accentPink : Colors.white).withValues(
              alpha: 0.92 * o,
            ),
        );

      // Disque net, plus clair que le rail. L'appui l'éclaircit encore.
      case CameraButtonStyle.plein:
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..color = Color.lerp(
              NeoNeutrals.gray800,
              NeoNeutrals.gray700,
              pressed,
            )!.withValues(alpha: o),
        );
        if (active) {
          canvas.drawCircle(
            center,
            r - 1,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = NeoTheme.accentPink.withValues(alpha: 0.9 * o),
          );
        }
    }
  }

  @override
  bool shouldRepaint(_ButtonPainter old) =>
      old.style != style ||
      old.pressed != pressed ||
      old.active != active ||
      old.enabled != enabled;
}

/// Entrée décalée : chaque contrôle arrive après le précédent.
///
/// Le rail apparaît en même temps que l'aperçu ; sans décalage, six disques
/// surgissent d'un bloc et l'œil ne sait pas où se poser. Le décalage donne un
/// ordre de lecture.
class _Entry extends StatefulWidget {
  const _Entry({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_Entry> createState() => _EntryState();
}

class _EntryState extends State<_Entry> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: NeoMotion.ample,
  );

  @override
  void initState() {
    super.initState();
    // 45 ms entre deux contrôles : au-delà, le rail met plus d'un tiers de
    // seconde à se former et l'attente devient perceptible.
    Future<void>.delayed(Duration(milliseconds: 45 * widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = NeoMotion.enter.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
