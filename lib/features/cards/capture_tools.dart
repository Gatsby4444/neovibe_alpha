import 'package:flutter/material.dart';

import '../../core/prefs.dart';
import '../../core/theme.dart';

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

/// Lueur blanche à beige affichée **sur le contour de l'écran**, comme la
/// lampe annulaire d'un créateur de contenu : elle éclaire le visage en
/// frontale, faute de LED en façade sur la plupart des appareils.
///
/// Elle est allumée **en permanence tant que le flash frontal est actif**
/// (arbitrage Jay 2026-07-26), et non au seul moment du déclenchement : c'est
/// ce qui permet de la régler en la voyant, et de filmer avec.
///
/// Les pixels sont dessinés PAR-DESSUS l'aperçu : la photo, elle, ne les
/// contient pas — c'est le visage éclairé que la caméra capture.
class ScreenFlashOverlay extends StatelessWidget {
  const ScreenFlashOverlay({super.key, required this.settings});

  final ScreenFlashSettings settings;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ScreenFlashPainter(settings),
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

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color.lerp(_cold, _warm, settings.warmth)!;
    final intensity = settings.intensity;

    // Largeur des bandes : de 4 % à 55 % du petit côté. Au maximum, les bandes
    // opposées se recouvrent — TOUT l'écran est illuminé, ce qui est bien ce
    // que Jay demande (« plus le curseur est poussé, plus la surface de l'écran
    // est illuminée »).
    final band = size.shortestSide * (0.04 + 0.51 * intensity);
    // Une lampe qu'on pousse n'est pas seulement plus large : elle est aussi
    // plus forte.
    final alpha = 0.5 + 0.5 * intensity;
    // Part de la bande qui reste PLEINE avant le dégradé de fondu. À faible
    // intensité, tout est fondu (halo doux) ; à forte intensité, l'essentiel
    // est plein et seul le bord intérieur s'adoucit.
    final solid = 0.65 * intensity;

    void edge(Rect rect, Alignment begin, Alignment end) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: begin,
            end: end,
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
            stops: [0, solid, 1],
          ).createShader(rect),
      );
    }

    edge(
      Rect.fromLTWH(0, 0, size.width, band),
      Alignment.topCenter,
      Alignment.bottomCenter,
    );
    edge(
      Rect.fromLTWH(0, size.height - band, size.width, band),
      Alignment.bottomCenter,
      Alignment.topCenter,
    );
    edge(
      Rect.fromLTWH(0, 0, band, size.height),
      Alignment.centerLeft,
      Alignment.centerRight,
    );
    edge(
      Rect.fromLTWH(size.width - band, 0, band, size.height),
      Alignment.centerRight,
      Alignment.centerLeft,
    );
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
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            widthFactor: _open ? 1 : 0,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: const Duration(milliseconds: 140),
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
        IconButton.filledTonal(
          tooltip: 'Flash frontal (lueur d\'écran)',
          icon: Icon(
            widget.on ? Icons.wb_incandescent : Icons.wb_incandescent_outlined,
            color: widget.on ? NeoTheme.accentPink : null,
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
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            widthFactor: _open ? 1 : 0,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: const Duration(milliseconds: 140),
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
        IconButton.filledTonal(
          tooltip: 'Retardateur',
          icon: armed
              ? Text(
                  '${widget.seconds}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: NeoTheme.accentPink,
                  ),
                )
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
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutBack,
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
    return IconButton.filledTonal(
      tooltip: active ? 'HD activé (photos)' : 'HD désactivé',
      icon: Icon(
        active ? Icons.hd : Icons.hd_outlined,
        color: active ? NeoTheme.accentPink : null,
      ),
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
    return IconButton.filledTonal(
      tooltip: active ? 'Masquer la grille' : 'Afficher la grille',
      icon: Icon(
        active ? Icons.grid_on : Icons.grid_off,
        color: active ? NeoTheme.accentPink : null,
      ),
      onPressed: onChanged == null ? null : () => onChanged!(!active),
    );
  }
}
