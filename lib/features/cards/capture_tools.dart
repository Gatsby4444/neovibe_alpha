import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';

import '../../core/prefs.dart';
import '../../core/theme.dart';
import 'camera_controls.dart';

/// Outils de PRISE de l'écran de capture (consigne Jay 2026-07-26) : flash
/// frontal (lueur d'écran), grille de cadrage, retardateur et HD.
///
/// Ce sont des aides de prise de vue, jamais de la post-production : elles
/// changent ce que la caméra voit, pas ce qu'on fait de l'image ensuite.
///
/// **Exclus du Oneshot** (règle : le Oneshot n'hérite de rien) et **du BeReal**
/// (consigne Jay : « j'ai d'autres projets pour le BeReal »). Le flash frontal
/// fait exception au BeReal : il prend la place du flash arrière, qui y existait
/// déjà.

// ---------------------------------------------------------------------------
// Flash frontal : lueur d'écran
// ---------------------------------------------------------------------------

/// Lueur blanche à beige occupant **toute la surface de l'écran**, comme la
/// lampe annulaire d'un créateur de contenu : elle éclaire le visage en
/// frontale, faute de LED en façade sur la plupart des appareils.
///
/// Elle est allumée **en permanence tant que le flash frontal est actif**
/// (arbitrage Jay 2026-07-26), et non au seul moment du déclenchement : c'est
/// ce qui permet de la régler en la voyant, et de filmer avec.
///
/// **Principe de rendu (corrigé après le test de Jay, 2026-07-26)** :
/// les pixels du bandeau sont à **luminosité MAXIMALE d'emblée** — le curseur
/// d'intensité ne change pas leur éclat, il règle **jusqu'où le bandeau se
/// propage vers l'intérieur** de l'écran. Le fondu vers le centre est
/// purement stylistique, pour adoucir le bord intérieur, et ses **coins sont
/// arrondis**. C'est le fonctionnement de Snapchat, et la première version s'en
/// écartait : elle baissait la luminosité à faible intensité, ce qui donnait
/// une lueur terne au lieu d'un bandeau fin mais franc.
///
/// **Bandeau du BAS plus épais (retour Jay, 2026-07-31)** : sur Snapchat le
/// bandeau n'a pas la même épaisseur sur les quatre bords — en bas il part
/// **déjà épais (~1/8 de la hauteur d'écran), constant**, et c'est seulement
/// à partir de là que le curseur le fait grossir. C'est l'éclairage par le bas
/// qui déblesse le visage (la lumière du menton), d'où le plancher. Les trois
/// autres bords partent fins, comme avant.
///
/// Les pixels sont dessinés PAR-DESSUS l'aperçu : la photo, elle, ne les
/// contient pas — c'est le visage éclairé que la caméra capture.
class ScreenFlashOverlay extends StatelessWidget {
  const ScreenFlashOverlay({super.key, required this.settings});

  final ScreenFlashSettings settings;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // Isolée du reste : l'aperçu caméra repeint 30 fois par seconde, la
      // lueur ne bouge que quand on touche un curseur.
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ScreenFlashPainter(settings),
        ),
      ),
    );
  }
}

class _ScreenFlashPainter extends CustomPainter {
  const _ScreenFlashPainter(this.settings);

  final ScreenFlashSettings settings;

  /// Blanc franc → beige chaud (~3200 K, la teinte d'une lampe de tournage).
  static const _cold = Color(0xFFFFFFFF);
  static const _warm = Color(0xFFFFD6A0);

  /// Nombre de passes d'évidement du fondu intérieur.
  static const _steps = 26;

  /// Fraction retirée à chaque passe, telle qu'après [_steps] passes il ne
  /// reste que 2 % — le centre est donc bien transparent.
  static final double _bite = 1 - math.pow(0.02, 1 / _steps).toDouble();

  /// Part du bandeau occupée par le FONDU vers l'intérieur : franc côté bord,
  /// adouci côté centre.
  static const _fadeShare = 0.55;

  /// Plancher du bandeau du BAS — part de la hauteur d'écran **réellement
  /// éclairée** (retour Jay 2026-07-31 : « en bas il commence épais sur environ
  /// 1/8 de l'écran, constant, et l'épaississement commence à partir de là »).
  ///
  /// C'est bien la part VISIBLE, pas la profondeur brute : la moitié intérieure
  /// du bandeau étant un fondu, la profondeur à demander est plus grande (voir
  /// [paint]). Mesuré : sans cette conversion, le bandeau ne faisait que 6,8 %
  /// de la hauteur au lieu des 12,5 % demandés.
  static const _bottomLit = 1 / 8;

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color.lerp(_cold, _warm, settings.warmth)!;
    final bounds = Offset.zero & size;
    final short = size.shortestSide;

    // **Profondeur de propagation** du bandeau vers l'intérieur : c'est le seul
    // rôle du curseur d'intensité.
    //
    // Le maximum (1,15 × le petit côté) est calibré pour qu'à FOND DE CURSEUR
    // le trou central ait entièrement disparu — tout l'écran est alors blanc à
    // 100 %, comme sur Snapchat. Le trou se referme quand `reach - fade`
    // dépasse la moitié du petit côté, soit `reach > short / (2 × 0,45)`
    // = 1,11 × short ; la marge évite qu'une dernière passe d'effacement
    // grise l'écran entier.
    //
    // Profil obtenu, vérifié hors Flutter sur un écran 393 × 852 : 34 % de la
    // largeur éclairée au quart du curseur, 65 % à mi-course, 95 % aux trois
    // quarts, 100 % à fond.
    final reach = short * (0.05 + 1.10 * settings.intensity);
    // Bandeau du BAS : même propagation, mais **jamais moins d'un huitième de
    // l'écran éclairé**. Le curseur ne le fait donc grossir qu'une fois ce
    // plancher dépassé — le comportement décrit par Jay sur Snapchat.
    // Division par [_fadeShare] : le fondu mange la moitié intérieure du
    // bandeau, il faut donc demander plus de profondeur que de lumière visible.
    final bottomReach = math.max(reach, size.height * _bottomLit / _fadeShare);
    // Chaque bord fond sur SA propre profondeur, sans quoi le bas garderait le
    // fondu d'un bandeau fin sur une bande large (frontière nette au lieu d'un
    // dégradé).
    final fade = reach * _fadeShare;
    final bottomFade = bottomReach * _fadeShare;
    // Coins intérieurs arrondis (demande de Jay) : le rayon suit la propagation
    // pour rester proportionné, mais il est **borné au tiers du petit côté de
    // l'ouverture** — sans cette borne, le trou vire à l'ovale dès que le
    // bandeau se referme, alors qu'on veut un rectangle aux coins adoucis.
    double radiusFor(Rect hole) =>
        math.min(reach * 0.8 + short * 0.04, hole.shortestSide * 0.33);

    canvas.saveLayer(bounds, Paint());
    // 1. Tout l'écran, à pleine luminosité.
    canvas.drawRect(bounds, Paint()..color = color);

    // 2. On évide le centre par rectangles arrondis concentriques, du plus
    //    large (près du bord) au plus étroit : chaque passe retire une fraction
    //    constante de ce qui reste, ce qui produit un fondu doux SANS
    //    `MaskFilter.blur` — un flou plein écran serait recalculé à chaque
    //    image de l'aperçu.
    final erase = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = Colors.black.withValues(alpha: _bite);
    for (var i = 0; i < _steps; i++) {
      final k = 1 - i / (_steps - 1);
      final inset = reach - fade * k;
      final bottomInset = bottomReach - bottomFade * k;
      // Bords indépendants : le trou n'est plus centré, il est remonté par le
      // bandeau du bas.
      final hole = Rect.fromLTRB(
        inset,
        inset,
        size.width - inset,
        size.height - bottomInset,
      );
      // Le bandeau s'est refermé sur lui-même : plus rien à évider.
      if (hole.isEmpty) break;
      canvas.drawRRect(
        RRect.fromRectAndRadius(hole, Radius.circular(radiusFor(hole))),
        erase,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScreenFlashPainter old) =>
      old.settings.warmth != settings.warmth ||
      old.settings.intensity != settings.intensity;
}

/// Bouton du FLASH FRONTAL + son menu de réglage, déplié vers la gauche comme
/// celui du flash arrière (consigne Jay).
///
/// Deux différences avec l'arrière, voulues : il n'y a **pas d'automatique**
/// (« c'est uniquement manuel, comme sur Snap »), et le menu porte les deux
/// curseurs — chaleur et intensité.
class ScreenFlashControl extends StatefulWidget {
  const ScreenFlashControl({
    super.key,
    required this.on,
    required this.settings,
    required this.onToggle,
    required this.onChanged,
  });

  final bool on;
  final ScreenFlashSettings settings;
  final ValueChanged<bool> onToggle;
  final ValueChanged<ScreenFlashSettings> onChanged;

  @override
  State<ScreenFlashControl> createState() => _ScreenFlashControlState();
}

class _ScreenFlashControlState extends State<ScreenFlashControl> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Même mécanique que le flash arrière : le panneau occupe la place à
        // GAUCHE du bouton, sa largeur s'anime.
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.centerRight,
            duration: NeoMotion.normal,
            curve: NeoMotion.enter,
            widthFactor: _open ? 1 : 0,
            // ⚠️ `heightFactor` AUTANT que `widthFactor` — corrigé le
            // 2026-08-15. Replier la seule largeur laissait le panneau
            // **occuper toute sa hauteur** : la ligne du flash frontal (des
            // curseurs, ~130 px) était donc trois fois plus haute que celle du
            // flash arrière (une rangée d'icônes), et la colonne centrée du
            // rail ne tombait pas au même endroit selon la caméra.
            //
            // C'est ce que Jay décrivait par « la disposition des boutons de la
            // vue frontale est différente ». Le défaut ne se voyait PAS sur le
            // panneau lui-même — il était invisible et poussait ses voisins.
            heightFactor: _open ? 1 : 0,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: NeoMotion.fast,
              child: Container(
                width: 234,
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Éteint / allumé, en pictogrammes seuls — pas
                    // d'automatique (consigne Jay).
                    Row(
                      children: [
                        for (final on in [false, true])
                          IconButton(
                            iconSize: 20,
                            visualDensity: VisualDensity.compact,
                            tooltip: on ? 'Lueur allumée' : 'Lueur éteinte',
                            icon: Icon(
                              on ? Icons.wb_incandescent : Icons.flash_off,
                              color: on == widget.on
                                  ? NeoTheme.accentPink
                                  : Colors.white,
                            ),
                            onPressed: () => widget.onToggle(on),
                          ),
                      ],
                    ),
                    _slider(
                      icon: Icons.thermostat,
                      label: 'Chaleur',
                      value: widget.settings.warmth,
                      onChanged: (v) =>
                          widget.onChanged(widget.settings.copyWith(warmth: v)),
                    ),
                    _slider(
                      icon: Icons.brightness_6,
                      label: 'Intensité',
                      value: widget.settings.intensity,
                      onChanged: (v) => widget.onChanged(
                        widget.settings.copyWith(intensity: v),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        CameraButton(
          tooltip: 'Flash frontal (lueur d\'écran)',
          active: widget.on,
          icon: Icon(
            widget.on ? Icons.wb_incandescent : Icons.wb_incandescent_outlined,
          ),
          onPressed: () => setState(() => _open = !_open),
        ),
      ],
    );
  }

  Widget _slider({
    required IconData icon,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white70),
        const SizedBox(width: 4),
        SizedBox(
          width: 54,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(value: value, onChanged: onChanged),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bascule de caméra au double-tap
// ---------------------------------------------------------------------------

/// Petite animation jouée au **double-tap de bascule caméra** (demande de Jay
/// 2026-07-31), en plus du retour haptique : un pictogramme de bascule qui
/// grossit, pivote d'un demi-tour et s'efface.
///
/// Elle se superpose au voile de bascule (le fond sombre qui masque la
/// transition) : c'est justement pendant ce temps mort qu'il faut montrer que
/// le geste a été pris en compte — sans elle, un double-tap se lit comme un
/// gel de l'aperçu.
class LensSwitchBurst extends StatelessWidget {
  const LensSwitchBurst({super.key, required this.animation});

  /// Progression 0 → 1 ; à 0, rien n'est dessiné.
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = animation.value;
          if (t == 0) return const SizedBox.shrink();
          // Apparition franche (premier quart) puis effacement progressif.
          final opacity = (t < 0.25 ? t / 0.25 : 1 - (t - 0.25) / 0.75).clamp(
            0.0,
            1.0,
          );
          final eased = NeoMotion.enter.transform(t);
          return Center(
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: 0.7 + 0.5 * eased,
                child: Transform.rotate(angle: math.pi * eased, child: child),
              ),
            ),
          );
        },
        // Construit UNE fois : seules l'échelle, la rotation et l'opacité
        // changent d'une image à l'autre.
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.38),
            border: Border.all(color: Colors.white24, width: 1.5),
          ),
          child: const Icon(
            Icons.cameraswitch_rounded,
            size: 34,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grille de cadrage
// ---------------------------------------------------------------------------

/// Grille des tiers, dessinée dans le cadre 9:16 de l'aperçu — donc sur
/// exactement ce qui sera capturé, pas sur tout l'écran.
class CaptureGridOverlay extends StatelessWidget {
  const CaptureGridOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(size: Size.infinite, painter: const _GridPainter()),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Deux traits : un noir légèrement décalé sous un blanc translucide, pour
    // que la grille reste lisible sur un sujet clair comme sur un sujet sombre.
    final shadow = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1.6;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..strokeWidth = 1;

    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), shadow);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), shadow);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Retardateur
// ---------------------------------------------------------------------------

/// Bouton du retardateur + menu déplié vers la gauche : 3, 5 ou 10 s
/// (consigne Jay), ou aucun.
class CaptureTimerControl extends StatefulWidget {
  const CaptureTimerControl({
    super.key,
    required this.seconds,
    required this.onChanged,
  });

  /// Retardateur armé, en secondes. 0 = aucun.
  final int seconds;
  final ValueChanged<int>? onChanged;

  /// Les seules valeurs proposées (consigne Jay).
  static const choices = [3, 5, 10];

  @override
  State<CaptureTimerControl> createState() => _CaptureTimerControlState();
}

class _CaptureTimerControlState extends State<CaptureTimerControl> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final armed = widget.seconds > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.centerRight,
            duration: NeoMotion.normal,
            curve: NeoMotion.enter,
            widthFactor: _open ? 1 : 0,
            // ⚠️ `heightFactor` AUTANT que `widthFactor` — corrigé le
            // 2026-08-15. Replier la seule largeur laissait le panneau
            // **occuper toute sa hauteur** : la ligne du flash frontal (des
            // curseurs, ~130 px) était donc trois fois plus haute que celle du
            // flash arrière (une rangée d'icônes), et la colonne centrée du
            // rail ne tombait pas au même endroit selon la caméra.
            //
            // C'est ce que Jay décrivait par « la disposition des boutons de la
            // vue frontale est différente ». Le défaut ne se voyait PAS sur le
            // panneau lui-même — il était invisible et poussait ses voisins.
            heightFactor: _open ? 1 : 0,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: NeoMotion.fast,
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Sans retardateur',
                      icon: Icon(
                        Icons.timer_off,
                        color: armed ? Colors.white : NeoTheme.accentPink,
                      ),
                      onPressed: () => _pick(0),
                    ),
                    for (final value in CaptureTimerControl.choices)
                      IconButton(
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        tooltip: '$value secondes',
                        icon: Text(
                          '$value',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: value == widget.seconds
                                ? NeoTheme.accentPink
                                : Colors.white,
                          ),
                        ),
                        onPressed: () => _pick(value),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        CameraButton(
          tooltip: 'Retardateur',
          active: armed,
          // Le nombre de secondes remplace l'icône quand le retardateur est
          // armé ; son style vient du bouton, il n'est plus écrit ici.
          icon: armed
              ? Text('${widget.seconds}')
              : const Icon(Icons.timer_outlined),
          onPressed: widget.onChanged == null
              ? null
              : () => setState(() => _open = !_open),
        ),
      ],
    );
  }

  void _pick(int value) {
    setState(() => _open = false);
    widget.onChanged?.call(value);
  }
}

/// Décompte du retardateur : un grand chiffre au centre de l'écran.
class CountdownOverlay extends StatelessWidget {
  const CountdownOverlay({super.key, required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        // La clé sur le chiffre fait rejouer l'animation à CHAQUE seconde,
        // sans quoi le décompte changerait de valeur sans bouger.
        child: TweenAnimationBuilder<double>(
          key: ValueKey(seconds),
          tween: Tween(begin: 1.35, end: 1),
          duration: NeoMotion.normal,
          curve: NeoMotion.spring,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Text(
            '$seconds',
            style: const TextStyle(
              fontSize: 96,
              fontWeight: FontWeight.w300,
              color: Colors.white,
              shadows: [Shadow(blurRadius: 24, color: Colors.black87)],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HD
// ---------------------------------------------------------------------------

/// Bouton HD : la face est normalisée en 1440×2560 au lieu de 900×1600.
///
/// **Photos uniquement** (arbitrage Jay 2026-07-26) : la vidéo reste plafonnée
/// par la limite d'upload Supabase (50 Mo/fichier). Le bouton n'est pas masqué
/// pour autant — il s'arme AVANT la prise, sans savoir si ce sera une photo ou
/// une vidéo ; sur une vidéo, il ne change simplement rien. Vidéo HD à revoir
/// quand l'hébergement le permettra (`RAPPELS.md`).
class HdButton extends StatelessWidget {
  const HdButton({super.key, required this.active, required this.onChanged});

  final bool active;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return CameraButton(
      tooltip: active ? 'HD activé (photos)' : 'HD désactivé',
      active: active,
      icon: Icon(active ? Icons.hd : Icons.hd_outlined),
      onPressed: onChanged == null ? null : () => onChanged!(!active),
    );
  }
}

/// Bouton de la grille de cadrage — simple bascule, l'état vit dans les
/// préférences (`captureGridProvider`).
class GridButton extends StatelessWidget {
  const GridButton({super.key, required this.active, required this.onChanged});

  final bool active;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return CameraButton(
      tooltip: active ? 'Masquer la grille' : 'Afficher la grille',
      active: active,
      icon: Icon(active ? Icons.grid_on : Icons.grid_off),
      onPressed: onChanged == null ? null : () => onChanged!(!active),
    );
  }
}
