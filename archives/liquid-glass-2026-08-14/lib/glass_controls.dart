/// Habillage « liquid glass » des contrôles de l'écran de capture.
///
/// Maquette proposée par Jay le 2026-08-14.
///
/// ## Deuxième version — la première n'était pas du liquid glass
///
/// Jay, après le test de la v0.9.75 : « **il n'y a pas l'effet liquid glass**. »
/// Il avait raison, et l'erreur mérite d'être écrite ici pour ne pas se
/// reproduire.
///
/// La v1 empilait un flou, une teinte claire et un **liseré irisé peint à la
/// main** (`SweepGradient`). C'est du verre **dépoli** — le matériau d'iOS 7 à
/// 18. Le liquid glass est un autre objet : une **lentille**. Ce qui le définit
/// n'est pas le flou, c'est que le fond y est **réfracté**, courbé au bord et
/// intact au centre. Et son irisation n'est pas une décoration : c'est la
/// **dispersion chromatique** de cette réfraction. Je peignais donc le symptôme
/// à la place de la cause — d'où un rendu qui ressemblait vaguement sans jamais
/// convaincre.
///
/// La v2 calcule la réfraction pour de bon, dans
/// `assets/shaders/liquid_glass.frag`.
///
/// ## Pourquoi c'est en Flutter et pas en Rive
///
/// Ce n'est pas une préférence, c'est une contrainte. Tout l'effet tient à ce
/// que les contrôles **déforment l'image caméra vivante** qui passe derrière.
/// Rive dessine son propre contenu vectoriel dans sa texture et n'a **aucun
/// accès à ce qui se trouve derrière lui** dans l'arbre Flutter. Rive reste le
/// bon outil pour les icônes animées **à l'intérieur** des boutons.
///
/// Deux conditions vérifiées avant d'écrire quoi que ce soit :
///
/// 1. L'aperçu est un `Texture` (`native_camera.dart:511`), donc composé
///    **dans** la scène Flutter — un filtre s'y applique. Avec une
///    `PlatformView`, rien de tout ceci n'aurait fonctionné.
/// 2. `ui.ImageFilter.shader` existe en Flutter 3.44.6 et lie automatiquement
///    l'arrière-plan au premier `sampler2D`. Il **exige Impeller**, actif par
///    défaut sur Android et non désactivé ici.
///
/// ## Un seul passage pour tout le rail
///
/// Les six lentilles de boutons sont calculées **dans le même shader** que le
/// rail. Un filtre par bouton aurait multiplié par sept la lecture du tampon
/// d'affichage. Possible parce que les boutons sont régulièrement espacés : le
/// shader retrouve le plus proche par le calcul.
///
/// ## Trois recettes, parce que le coût se mesure
///
/// [GlassQuality.liquid] (défaut), [GlassQuality.frosted] (le verre dépoli de
/// la v1, conservé comme repli intermédiaire) et [GlassQuality.light] (sans
/// aucune lecture du tampon). Voir `FrameCostTrace`.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Recette du verre. Le coût du rendu sur un aperçu caméra vivant **se mesure,
/// ne se devine pas** — d'où trois paliers plutôt qu'un choix binaire.
enum GlassQuality {
  /// Réfraction réelle par shader : le fond est courbé, avec sa dispersion.
  /// C'est le liquid glass.
  liquid,

  /// Verre dépoli : flou seul. Aucune réfraction. C'était la v1.
  frosted,

  /// Aucune lecture du tampon d'affichage : une teinte translucide en tient
  /// lieu. Coût négligeable.
  light;

  String get label => switch (this) {
    GlassQuality.liquid => 'liquid glass (réfraction)',
    GlassQuality.frosted => 'verre dépoli (flou seul)',
    GlassQuality.light => 'translucide (sans lecture du fond)',
  };
}

/// Réglages du verre. Groupés ici pour qu'un ajustement d'aspect ne demande pas
/// de relire le shader.
abstract final class _Glass {
  /// Flou appliqué SOUS la réfraction. Volontairement faible : le liquid glass
  /// laisse voir. C'est le verre dépoli qui masque, et c'est ce qu'on ne veut
  /// plus.
  static const liquidBlur = 3.5;

  /// Flou du repli dépoli, lui bien plus fort — sans réfraction, il ne reste
  /// que lui pour asseoir le matériau.
  static const frostedBlur = 18.0;

  /// Amplitude de la déviation, en pixels, au plus fort de la pente.
  static const refract = 34.0;

  /// Écart entre le rouge et le bleu. C'est **lui** qui produit l'irisation.
  /// Au-delà de ~0,25 le bord vire à l'arc-en-ciel de mauvais goût.
  static const dispersion = 0.14;

  static const specular = 0.42;

  /// Voile clair. Faible : le liquid glass reste transparent.
  static const tint = 0.10;

  /// Largeur du biseau du rail et des boutons — leur « épaisseur » de verre.
  static const railBevel = 16.0;
  static const buttonBevel = 13.0;

  static const railRadius = 34.0;
  static const buttonSize = 52.0;

  /// Marges internes du rail, autour de la colonne de boutons.
  static const padH = 6.0;
  static const padV = 8.0;

  /// Teinte du repli (sans shader).
  static const fallbackTop = Color(0x47FFFFFF);
  static const fallbackBottom = Color(0x24FFFFFF);
  static const fallbackScrim = Color(0x38000000);

  /// Icônes : sombres, comme la maquette. Le halo blanc les sauve quand la
  /// scène derrière est très lumineuse et très contrastée.
  static const icon = Color(0xFF15151A);
}

/// Chargement du shader, une fois pour toute l'app.
///
/// Asynchrone et **non bloquant** : tant qu'il n'est pas prêt (ou s'il échoue),
/// le rail rend le repli dépoli. Un écran de capture qui attendrait un shader
/// serait un écran de capture cassé.
class LiquidGlassProgram {
  LiquidGlassProgram._();

  static const asset = 'assets/shaders/liquid_glass.frag';

  /// Notifié une fois le programme prêt. `null` = pas (encore) disponible.
  static final ValueNotifier<ui.FragmentProgram?> program =
      ValueNotifier<ui.FragmentProgram?>(null);

  static bool _started = false;

  /// Pourquoi le liquid glass n'est pas actif, s'il ne l'est pas. Repris tel
  /// quel dans le diagnostic : sans ça, « pas d'effet » et « effet raté » sont
  /// indiscernables dans un rapport de test.
  static String status = 'shader pas encore chargé';

  static void ensureLoaded() {
    if (_started) return;
    _started = true;

    // `ImageFilter.shader` n'existe que sous Impeller. On le demande AVANT de
    // charger quoi que ce soit : échouer ici est une information, pas une
    // panne.
    if (!ui.ImageFilter.isShaderFilterSupported) {
      status = 'moteur sans Impeller — ImageFilter.shader indisponible';
      return;
    }
    _load();
  }

  static Future<void> _load() async {
    try {
      program.value = await ui.FragmentProgram.fromAsset(asset);
      status = 'actif';
    } catch (e) {
      // Un shader qui ne compile pas ne doit PAS emporter l'écran de capture
      // avec lui : on note pourquoi, et le rail retombe sur le dépoli.
      status = 'échec de chargement : $e';
    }
  }
}

/// Le rail vertical de contrôles, en verre.
///
/// Il impose une largeur fixe à sa surface de verre, et calcule lui-même la
/// position de chaque lentille de bouton — c'est ce qui permet au shader de
/// n'avoir besoin d'aucune mesure.
///
/// Les enfants sont posés **par-dessus** la surface, hors du découpage : les
/// menus qui s'ouvrent vers la gauche (flash, retardateur) débordent donc du
/// rail au lieu d'être coupés — et ne sont pas réfractés par lui, ce qui serait
/// faux : ils flottent à côté du verre, pas dedans.
class GlassRail extends StatefulWidget {
  const GlassRail({
    super.key,
    required this.children,
    this.quality = GlassQuality.liquid,
    this.spacing = 10,
  });

  final List<Widget> children;
  final GlassQuality quality;
  final double spacing;

  @override
  State<GlassRail> createState() => _GlassRailState();
}

class _GlassRailState extends State<GlassRail> {
  @override
  void initState() {
    super.initState();
    LiquidGlassProgram.ensureLoaded();
  }

  double get _width => _Glass.buttonSize + 2 * _Glass.padH;

  double get _height =>
      widget.children.length * _Glass.buttonSize +
      (widget.children.length - 1) * widget.spacing +
      2 * _Glass.padV;

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < widget.children.length; i++) ...[
          if (i > 0) SizedBox(height: widget.spacing),
          _StaggeredEntry(index: i, child: widget.children[i]),
        ],
      ],
    );

    return ValueListenableBuilder<ui.FragmentProgram?>(
      valueListenable: LiquidGlassProgram.program,
      builder: (context, program, _) {
        // Le liquide n'est demandé QUE si le shader est réellement là. Sinon on
        // retombe sur le dépoli — jamais sur un rail invisible.
        final refracted =
            widget.quality == GlassQuality.liquid && program != null;
        final surface = refracted
            ? _liquidSurface(program)
            : _fallbackSurface();

        return _GlassScope(
          refracted: refracted,
          // `Clip.none` + alignement à droite : la surface garde sa largeur
          // fixe, la colonne peut être plus large quand un menu s'ouvre, et ce
          // surplus déborde vers la gauche sans être coupé.
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerRight,
            children: [
              RepaintBoundary(
                child: SizedBox(width: _width, height: _height, child: surface),
              ),
              column,
            ],
          ),
        );
      },
    );
  }

  /// La surface réfractante : un `BackdropFilter` dont le filtre est le shader,
  /// composé par-dessus un flou léger.
  Widget _liquidSurface(ui.FragmentProgram program) {
    final shader = program.fragmentShader();
    final n = widget.children.length;

    // L'ordre des `setFloat` suit EXACTEMENT l'ordre de déclaration des
    // uniformes dans le `.frag`. Un décalage d'un cran ici ne lève aucune
    // erreur : il donne juste un rendu absurde. Toute modification du shader
    // doit rejouer cette liste.
    var i = 0;
    shader.setFloat(i++, _width); // uSize.x
    shader.setFloat(i++, _height); // uSize.y
    shader.setFloat(i++, _Glass.railRadius);
    shader.setFloat(i++, _Glass.railBevel);
    shader.setFloat(i++, _Glass.refract);
    shader.setFloat(i++, _Glass.dispersion);
    shader.setFloat(i++, _Glass.specular);
    shader.setFloat(i++, _Glass.tint);
    shader.setFloat(i++, n.toDouble());
    shader.setFloat(i++, _Glass.buttonSize / 2);
    shader.setFloat(i++, _Glass.buttonBevel);
    // Centre du premier bouton, puis pas entre deux centres. Ces deux valeurs
    // DOIVENT correspondre à la mise en page de la colonne ci-dessus : c'est le
    // seul endroit où la géométrie est dupliquée, et le seul à corriger si les
    // marges changent.
    shader.setFloat(i++, _Glass.padV + _Glass.buttonSize / 2);
    shader.setFloat(i++, _Glass.buttonSize + widget.spacing);
    shader.setFloat(i++, _width / 2);

    return ClipRRect(
      borderRadius: BorderRadius.circular(_Glass.railRadius),
      child: BackdropFilter(
        // `compose(outer, inner)` applique `inner` d'abord : on floute
        // légèrement, PUIS on réfracte le résultat. L'inverse donnerait une
        // réfraction lissée, donc molle.
        filter: ui.ImageFilter.compose(
          outer: ui.ImageFilter.shader(shader),
          inner: ui.ImageFilter.blur(
            sigmaX: _Glass.liquidBlur,
            sigmaY: _Glass.liquidBlur,
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// Repli : le verre dépoli de la v1, ou une simple teinte.
  Widget _fallbackSurface() {
    const fill = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_Glass.fallbackTop, _Glass.fallbackBottom],
        ),
      ),
      child: SizedBox.expand(),
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_Glass.railRadius),
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
        borderRadius: BorderRadius.circular(_Glass.railRadius - 1.2),
        child: widget.quality == GlassQuality.light
            ? const ColoredBox(color: _Glass.fallbackScrim, child: fill)
            : BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: _Glass.frostedBlur,
                  sigmaY: _Glass.frostedBlur,
                ),
                child: fill,
              ),
      ),
    );
  }
}

/// Dit aux boutons si le rail réfracte réellement.
///
/// Utile parce qu'un bouton ne doit PAS peindre son propre liseré irisé quand
/// le shader en produit un vrai : les deux se superposeraient, et le faux
/// gâcherait le vrai.
class _GlassScope extends InheritedWidget {
  const _GlassScope({required this.refracted, required super.child});

  final bool refracted;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassScope>()?.refracted ??
      false;

  @override
  bool updateShouldNotify(_GlassScope old) => old.refracted != refracted;
}

/// Bouton circulaire du rail.
///
/// Même API que l'`IconButton.filledTonal` qu'il remplace — `icon`, `tooltip`,
/// `onPressed` — pour que le remplacement ne touche à rien de ce que les
/// boutons **commandent**.
///
/// ⚠️ Il ne produit aucun verre lui-même : sa lentille est calculée par le
/// shader du [GlassRail], qui connaît sa position. Hors d'un rail, il reste
/// utilisable mais plat.
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

  /// État « armé » : l'icône prend l'accent. Convention du projet — le rose ne
  /// signale qu'une chose, ce qui est actif.
  final bool active;

  final double size;

  /// Contenu peint **sous** le verre, dans le disque — la pastille de couleur
  /// du bouton de fond de face.
  final Widget? underlay;

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
    final refracted = _GlassScope.of(context);

    // La zone de clic est EXACTEMENT le disque visible.
    //
    // Leçon du bouton d'envoi (2026-08-14) : un contrôle mis à l'échelle a deux
    // boîtes, et si elles diffèrent, la règle « relâcher hors de la zone annule »
    // devient vraie partout et ne veut plus rien dire. L'échelle est donc
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
                      refracted: refracted,
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

/// Ce qui reste à peindre sur un bouton.
///
/// **Quand le rail réfracte** (`refracted`), le liseré et le relief sont
/// produits par le shader : on ne peint qu'un appui — un assombrissement bref —
/// et l'état actif. Repeindre un liseré par-dessus le vrai les ferait se
/// contredire, et c'est exactement l'erreur de la v1.
///
/// **En repli**, on retrouve le liseré irisé peint et le reflet en arc : sans
/// shader, il ne reste rien d'autre pour donner du volume.
class _GlassButtonPainter extends CustomPainter {
  const _GlassButtonPainter({
    required this.pressed,
    required this.active,
    required this.enabled,
    required this.refracted,
  });

  final double pressed;
  final bool active;
  final bool enabled;
  final bool refracted;

  /// Angle de départ du liseré peint, en radians — un peu avant midi, à gauche.
  static const _sweepStart = -2.4;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2;
    final opacity = enabled ? 1.0 : 0.45;

    if (refracted) {
      // Retour d'appui : le verre s'enfonce et s'assombrit légèrement. C'est le
      // seul ajout — tout le relief vient du shader.
      if (pressed > 0) {
        canvas.drawCircle(
          center,
          radius,
          Paint()..color = Color.fromRGBO(0, 0, 0, 0.16 * pressed),
        );
      }
      if (active) {
        canvas.drawCircle(
          center,
          radius - 1.2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = NeoTheme.accentPink.withValues(alpha: 0.85 * opacity),
        );
      }
      return;
    }

    // --- Repli : tout est peint ---------------------------------------
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

    final sheen = 1 + 0.6 * pressed;
    double a(double base) => (base * opacity * sheen).clamp(0.0, 1.0);
    canvas.drawCircle(
      center,
      radius - 0.9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = ui.Gradient.sweep(
          center,
          [
            const Color(0xFFCFE0FF).withValues(alpha: a(0.85)),
            Colors.white.withValues(alpha: a(0.95)),
            active
                ? NeoTheme.accentPink.withValues(
                    alpha: (0.90 * opacity).clamp(0.0, 1.0),
                  )
                : const Color(0xFFFFD6EF).withValues(alpha: a(0.80)),
            const Color(0xFFD9F0FF).withValues(alpha: a(0.70)),
            const Color(0xFFCFE0FF).withValues(alpha: a(0.85)),
          ],
          const [0.0, 0.25, 0.55, 0.8, 1.0],
          TileMode.clamp,
          _sweepStart,
          _sweepStart + 6.2831853,
        ),
    );

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
      old.pressed != pressed ||
      old.active != active ||
      old.enabled != enabled ||
      old.refracted != refracted;
}

/// Entrée décalée : chaque bouton arrive légèrement après le précédent.
///
/// Ce n'est pas de la décoration. Le rail apparaît en même temps que l'aperçu ;
/// sans décalage, six disques surgissent d'un bloc et l'œil ne sait pas où se
/// poser. Le décalage donne un ordre de lecture.
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
