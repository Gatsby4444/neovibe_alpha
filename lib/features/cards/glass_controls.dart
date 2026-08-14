/// Habillage « verre » des contrôles de l'écran de capture.
///
/// Maquette proposée par Jay le 2026-08-14 : un rail vertical en verre dépoli
/// à droite de l'aperçu, contenant des boutons circulaires à liseré nacré.
///
/// ## Pourquoi c'est en Flutter et pas en Rive
///
/// Ce n'est pas une préférence, c'est une contrainte. Tout l'effet tient à une
/// chose : les contrôles **floutent l'image caméra vivante** qui passe
/// derrière. Rive dessine son propre contenu vectoriel dans sa texture et n'a
/// **aucun accès à ce qui se trouve derrière lui** dans l'arbre Flutter — il ne
/// peut ni flouter, ni réfracter un aperçu caméra. Rive reste le bon outil pour
/// les icônes animées **à l'intérieur** des boutons (l'éclair qui se barre, le
/// cadran du retardateur) : petites, opaques, autonomes.
///
/// Condition vérifiée avant d'écrire une ligne : l'aperçu est un `Texture`
/// (`native_camera.dart:511`), donc composé **dans** la scène Flutter. Un
/// `BackdropFilter` s'y applique correctement. Avec une `PlatformView`, rien de
/// tout ceci n'aurait fonctionné.
///
/// ## Un seul flou pour tout le rail
///
/// Décision de coût, prise d'emblée. Un `BackdropFilter` force un `saveLayer`
/// et relit le tampon d'affichage : en donner un à chacun des six boutons **en
/// plus** de celui du rail multiplierait la dépense par sept, pour un rendu que
/// l'œil ne distingue pas. Le rail floute **une fois** ; les boutons ne sont
/// que de la peinture posée sur cette surface déjà dépolie.
///
/// C'est aussi ce qui rend le repli possible : en [GlassQuality.light], seul le
/// rail change de recette, les boutons sont identiques au pixel près.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Recette du verre. Le repli existe parce que le coût du flou sur un aperçu
/// caméra vivant **se mesure, ne se devine pas** — voir `FrameCostTrace`.
enum GlassQuality {
  /// Vrai verre dépoli : `BackdropFilter`, l'arrière-plan est réellement flouté.
  full,

  /// Repli économique : aucune lecture du tampon d'affichage, une teinte
  /// translucide un peu plus dense en tient lieu. Rend l'essentiel de l'effet
  /// pour un coût négligeable. À utiliser si la mesure condamne le flou.
  light;

  String get label => switch (this) {
    GlassQuality.full => 'verre dépoli (flou réel)',
    GlassQuality.light => 'verre économique (sans flou)',
  };
}

/// Nuances du verre, communes au rail et aux boutons.
abstract final class _Glass {
  /// Force du flou. 18 est le seuil au-delà duquel l'arrière-plan cesse d'être
  /// lisible : c'est ce qui distingue un verre d'une simple vitre teintée.
  static const blur = 18.0;

  /// Teinte du rail. Assez dense pour garantir un fond CLAIR quelle que soit
  /// la scène derrière — c'est elle qui permet aux icônes d'être sombres,
  /// comme sur la maquette, sans devenir illisibles de nuit.
  static const railTop = Color(0x47FFFFFF);
  static const railBottom = Color(0x24FFFFFF);

  /// En repli, le flou ne dilue plus la scène : on compense par un voile
  /// sombre sous la teinte claire, sinon un fond chargé traverse le rail.
  static const railScrim = Color(0x38000000);

  /// Nacre du liseré — bleu pâle, blanc, rose pâle. Ce sont ces trois-là qui
  /// donnent l'irisation ; un dégradé gris ne produit que du métal.
  static const sheenBlue = Color(0xFFCFE0FF);
  static const sheenWhite = Color(0xFFFFFFFF);
  static const sheenPink = Color(0xFFFFD6EF);
  static const sheenCyan = Color(0xFFD9F0FF);

  /// Icônes : sombres sur le verre clair, comme la maquette. Le halo blanc les
  /// sauve quand la scène derrière est très lumineuse ET très contrastée.
  static const icon = Color(0xFF15151A);

  static const radius = 34.0;
  static const buttonSize = 52.0;
}

/// Le rail vertical : la surface de verre qui porte les boutons.
///
/// Il floute **une seule fois**, pour tous ses enfants (voir l'en-tête).
class GlassRail extends StatelessWidget {
  const GlassRail({
    super.key,
    required this.children,
    this.quality = GlassQuality.full,
    this.spacing = 10,
  });

  final List<Widget> children;
  final GlassQuality quality;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          _StaggeredEntry(index: i, child: children[i]),
        ],
      ],
    );

    final surface = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_Glass.railTop, _Glass.railBottom],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: column,
      ),
    );

    // `RepaintBoundary` : l'aperçu caméra repeint en continu sous le rail. Sans
    // cette isolation, le moindre repaint du rail entraînerait celui de ses
    // voisins dans la même couche.
    return RepaintBoundary(
      child: Container(
        // Le liseré nacré : un dégradé peint sur 1,2 px, masqué au centre par
        // la surface elle-même.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_Glass.radius),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0x8FFFFFFF),
              Color(0x30FFFFFF),
              Color(0x66FFD6EF),
              Color(0x2AFFFFFF),
            ],
            stops: [0.0, 0.35, 0.72, 1.0],
          ),
        ),
        padding: const EdgeInsets.all(1.2),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_Glass.radius - 1.2),
          child: switch (quality) {
            GlassQuality.full => BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: _Glass.blur,
                sigmaY: _Glass.blur,
              ),
              child: surface,
            ),
            GlassQuality.light => ColoredBox(
              color: _Glass.railScrim,
              child: surface,
            ),
          },
        ),
      ),
    );
  }
}

/// Bouton circulaire en verre : liseré nacré, reflet spéculaire, ressort à
/// l'appui.
///
/// Même API que l'`IconButton.filledTonal` qu'il remplace — `icon`, `tooltip`,
/// `onPressed` — pour que le remplacement ne touche à rien de ce que les
/// boutons **commandent**.
///
/// ⚠️ Il ne floute pas lui-même : il se pose sur la surface déjà dépolie du
/// [GlassRail]. Utilisé hors d'un rail, il reste correct mais sans verre.
class GlassCircleButton extends StatefulWidget {
  const GlassCircleButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.onLongPress,
    this.active = false,
    this.size = _Glass.buttonSize,
    this.underlay,
  });

  final Widget icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// Contenu peint **sous** le verre, à l'intérieur du disque — la pastille de
  /// couleur du bouton de fond de face. Le corps translucide et le liseré se
  /// posent par-dessus : c'est ce qui donne une couleur vue à travers le verre
  /// plutôt qu'une gommette collée dessus.
  final Widget? underlay;

  /// État « armé » : le liseré rosit et l'icône prend l'accent. Convention du
  /// projet — le rose ne signale qu'une chose, ce qui est actif.
  final bool active;

  final double size;

  @override
  State<GlassCircleButton> createState() => _GlassCircleButtonState();
}

class _GlassCircleButtonState extends State<GlassCircleButton>
    with SingleTickerProviderStateMixin {
  late final _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 260),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onPressed != null || widget.onLongPress != null;

  @override
  Widget build(BuildContext context) {
    // La zone de clic est EXACTEMENT le disque visible.
    //
    // Leçon du bouton d'envoi (2026-08-14) : un contrôle mis à l'échelle a deux
    // boîtes, et si elles diffèrent, la règle « relâcher hors de la zone annule »
    // devient vraie partout et ne veut plus rien dire. Ici l'échelle est
    // appliquée SOUS le détecteur de gestes, jamais au-dessus.
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _press.forward() : null,
      onTapUp: _enabled ? (_) => _press.reverse() : null,
      onTapCancel: _enabled ? () => _press.reverse() : null,
      onTap: widget.onPressed,
      onLongPress: widget.onLongPress,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, child) {
            final t = Curves.easeOut.transform(_press.value);
            return Transform.scale(
              // Retour en `easeOutBack` : le disque dépasse très légèrement sa
              // taille au relâchement. C'est ce dépassement qui fait « ressort »
              // plutôt que « glissière ».
              scale: 1 - 0.10 * t,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.underlay != null) ClipOval(child: widget.underlay),
                  CustomPaint(
                    painter: _GlassButtonPainter(
                      pressed: t,
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
                size: 21,
                color: widget.active
                    ? NeoTheme.accentPink
                    : _Glass.icon.withValues(alpha: _enabled ? 1 : 0.35),
                shadows: const [
                  // Halo blanc : ce qui sauve une icône sombre quand la scène
                  // derrière le verre est à la fois très claire et très
                  // contrastée.
                  Shadow(color: Color(0x99FFFFFF), blurRadius: 6),
                ],
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: widget.active ? NeoTheme.accentPink : _Glass.icon,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  shadows: const [
                    Shadow(color: Color(0x99FFFFFF), blurRadius: 6),
                  ],
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
      // Sur mobile, une infobulle se déclenche à l'APPUI LONG — le même geste
      // que la palette du bouton de couleur. Les deux se disputeraient l'arène
      // des gestes. Quand le bouton a sa propre action d'appui long, c'est elle
      // qui gagne : l'infobulle passe en déclenchement manuel, donc jamais.
      triggerMode: widget.onLongPress != null
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: button,
    );
  }
}

/// Le disque : fond en dégradé radial, liseré irisé, reflet spéculaire.
///
/// Peint à la main plutôt qu'empilé en `Container`s : le liseré est un dégradé
/// **balayé** (`SweepGradient`) et le reflet un arc, ni l'un ni l'autre ne
/// s'obtient proprement avec une `BoxDecoration`.
class _GlassButtonPainter extends CustomPainter {
  const _GlassButtonPainter({
    required this.pressed,
    required this.active,
    required this.enabled,
  });

  final double pressed;
  final bool active;
  final bool enabled;

  /// Angle de départ du liseré, en radians — un peu avant midi, côté gauche.
  static const _sweepStart = -2.4;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2;
    final opacity = enabled ? 1.0 : 0.45;

    // 1. Le corps : plus clair en haut, comme un volume éclairé par le dessus.
    //    À l'appui il s'assombrit légèrement — le verre s'enfonce.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(center.dx - radius * 0.3, center.dy - radius * 0.45),
          radius * 1.5,
          [
            Color.lerp(
              const Color(0x59FFFFFF),
              const Color(0x33FFFFFF),
              pressed,
            )!.withValues(alpha: 0.35 * opacity),
            const Color(0x1AFFFFFF).withValues(alpha: 0.10 * opacity),
          ],
        ),
    );

    // 2. Le liseré irisé. Il s'éclaire à l'appui : c'est le retour visuel qui
    //    dit « touché » avant même que l'action ne parte.
    final sheen = 1 + 0.6 * pressed;
    canvas.drawCircle(
      center,
      radius - 0.9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = ui.Gradient.sweep(
          center,
          [
            _Glass.sheenBlue.withValues(
              alpha: (0.85 * opacity * sheen).clamp(0, 1),
            ),
            _Glass.sheenWhite.withValues(
              alpha: (0.95 * opacity * sheen).clamp(0, 1),
            ),
            active
                ? NeoTheme.accentPink.withValues(
                    alpha: (0.90 * opacity).clamp(0, 1),
                  )
                : _Glass.sheenPink.withValues(
                    alpha: (0.80 * opacity * sheen).clamp(0, 1),
                  ),
            _Glass.sheenCyan.withValues(
              alpha: (0.70 * opacity * sheen).clamp(0, 1),
            ),
            _Glass.sheenBlue.withValues(
              alpha: (0.85 * opacity * sheen).clamp(0, 1),
            ),
          ],
          const [0.0, 0.25, 0.55, 0.8, 1.0],
          TileMode.clamp,
          // Départ en haut à gauche : la source de lumière est cohérente avec
          // le dégradé du corps, sinon le volume se contredit.
          //
          // Obtenu en décalant l'angle de DÉPART, pas par une matrice : une
          // rotation `Matrix4` tourne autour de l'origine du canvas, pas du
          // centre du disque — il aurait fallu translater, tourner, retranslater
          // pour le même résultat.
          _sweepStart,
          _sweepStart + 2 * math.pi,
        ),
    );

    // 3. Le reflet spéculaire : un court arc clair en haut à gauche. C'est LUI
    //    qui fait lire la surface comme bombée ; sans lui le disque reste plat.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 3.5),
      -2.7,
      1.5,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.2
        ..shader = ui.Gradient.linear(rect.topLeft, rect.center, [
          Colors.white.withValues(alpha: 0.75 * opacity),
          Colors.white.withValues(alpha: 0.0),
        ]),
    );
  }

  @override
  bool shouldRepaint(_GlassButtonPainter old) =>
      old.pressed != pressed || old.active != active || old.enabled != enabled;
}

/// Entrée décalée : chaque bouton du rail arrive légèrement après le précédent,
/// en montant de quelques pixels.
///
/// Ce n'est pas de la décoration. Le rail apparaît en même temps que l'aperçu
/// caméra ; sans décalage, six disques surgissent d'un bloc et l'œil ne sait
/// pas où se poser. Le décalage donne un ordre de lecture.
class _StaggeredEntry extends StatefulWidget {
  const _StaggeredEntry({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_StaggeredEntry> createState() => _StaggeredEntryState();
}

class _StaggeredEntryState extends State<_StaggeredEntry>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    // 45 ms entre deux boutons : au-delà, le rail met plus d'un tiers de
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
        final t = Curves.easeOutCubic.transform(_controller.value);
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
