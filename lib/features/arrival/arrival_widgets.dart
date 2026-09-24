import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';

/// Les pièces visuelles de l'arrivée en soirée (test développeur).
///
/// **Le fil conducteur : LE ROND.** La direction « le rond » (2026-08-29)
/// devient ici un objet : un halo de lumière aux couleurs de la signature, vu
/// comme on voit la lumière d'un bar depuis la rue. Il porte d'abord une
/// initiale, puis la caméra, puis ton visage — c'est toi, qui entres.
///
/// ⚠️ Aucune couleur n'est écrite ici : tout vient de [NeoPalette] (règle de
/// `palette.dart`).

// Les lumières d'ambiance vivent dans `core/widgets/ambience.dart`
// (`NeoAmbience`) depuis qu'elles servent aussi l'identité Vice6.

/// **Le halo** : un rond de lumière qui respire, cerclé d'un anneau aux
/// couleurs de la signature qui tourne lentement. Ce qu'il contient change à
/// chaque étape ([child]).
class ArrivalHalo extends StatefulWidget {
  const ArrivalHalo({
    super.key,
    required this.size,
    this.child,
    this.breathing = true,
    this.ringSpeed = 1,
  });

  final double size;
  final Widget? child;

  /// La lueur autour respire. Coupée quand le rond sert de viseur.
  final bool breathing;

  /// Tours de l'anneau toutes les 6 s. 0 = immobile.
  final double ringSpeed;

  @override
  State<ArrivalHalo> createState() => _ArrivalHaloState();
}

class _ArrivalHaloState extends State<ArrivalHalo>
    with TickerProviderStateMixin {
  late final _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat(reverse: true);

  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _breath.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ring = math.max(3.0, widget.size * 0.035);
    return AnimatedContainer(
      duration: NeoMotion.ample,
      curve: NeoMotion.enter,
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_breath, _spin]),
        builder: (context, child) {
          final glow = widget.breathing
              ? 0.35 + 0.35 * Curves.easeInOut.transform(_breath.value)
              : 0.25;
          return DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: p.action.withValues(alpha: glow),
                  blurRadius: widget.size * 0.35,
                  spreadRadius: widget.size * 0.02,
                ),
                BoxShadow(
                  color: p.cool.withValues(alpha: glow * 0.7),
                  blurRadius: widget.size * 0.6,
                ),
              ],
              gradient: SweepGradient(
                transform: GradientRotation(
                  _spin.value * 2 * math.pi * widget.ringSpeed,
                ),
                colors: [p.warm, p.action, p.cool, p.action, p.warm],
              ),
            ),
            child: Padding(padding: EdgeInsets.all(ring), child: child),
          );
        },
        child: ClipOval(
          child: ColoredBox(
            color: p.surface,
            child: SizedBox.expand(child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// L'initiale du prénom, dans le halo — en dégradé, en Fredoka.
class HaloInitial extends StatelessWidget {
  const HaloInitial(this.letter, {super.key, required this.size});

  final String letter;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: AnimatedSwitcher(
        duration: NeoMotion.normal,
        transitionBuilder: (child, a) => ScaleTransition(
          scale: CurvedAnimation(parent: a, curve: NeoMotion.spring),
          child: FadeTransition(opacity: a, child: child),
        ),
        child: letter.isEmpty
            ? Icon(
                Icons.nightlife_rounded,
                key: const ValueKey('icon'),
                size: size * 0.38,
                color: p.inkMuted,
              )
            : ShaderMask(
                key: ValueKey(letter),
                shaderCallback: (r) => p.signature.createShader(r),
                child: Text(
                  letter,
                  style: TextStyle(
                    fontFamily: NeoType.display,
                    fontWeight: FontWeight.w600,
                    fontSize: size * 0.5,
                    height: 1,
                    color: p.ink,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Les ondes du radar, qui partent du halo.
class SonarRings extends StatefulWidget {
  const SonarRings({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<SonarRings> createState() => _SonarRingsState();
}

class _SonarRingsState extends State<SonarRings>
    with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _wave.repeat();
  }

  @override
  void didUpdateWidget(SonarRings old) {
    super.didUpdateWidget(old);
    if (widget.active && !_wave.isAnimating) _wave.repeat();
    if (!widget.active && _wave.isAnimating) _wave.stop();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedOpacity(
      opacity: 1,
      duration: NeoMotion.normal,
      child: CustomPaint(
        painter: _SonarPainter(
          progress: _wave,
          color: p.action,
          visible: widget.active,
        ),
        child: widget.child,
      ),
    );
  }
}

class _SonarPainter extends CustomPainter {
  _SonarPainter({
    required this.progress,
    required this.color,
    required this.visible,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final bool visible;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final c = size.center(Offset.zero);
    final start = size.shortestSide / 2;
    final reach = size.shortestSide * 1.6;
    for (var i = 0; i < 3; i++) {
      final t = (progress.value + i / 3) % 1;
      final radius = start + (reach - start) * Curves.easeOut.transform(t);
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - t) * 0.55),
      );
    }
  }

  @override
  bool shouldRepaint(_SonarPainter old) =>
      old.color != color || old.visible != visible;
}

/// Le bouton principal : une pilule au dégradé de la signature.
class GlowButton extends StatelessWidget {
  const GlowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: NeoMotion.fast,
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: p.signatureCourte,
          borderRadius: BorderRadius.circular(NeoRadius.pill),
          boxShadow: [
            if (enabled)
              BoxShadow(
                color: p.action.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(NeoRadius.pill),
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              height: 58,
              child: Center(
                child: busy
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: p.onAction,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, color: p.onAction, size: 22),
                            const SizedBox(width: NeoSpace.sm),
                          ],
                          Text(
                            label,
                            style: TextStyle(
                              fontFamily: NeoType.display,
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                              color: p.onAction,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La progression : une barre par étape, remplie au dégradé.
class ArrivalProgress extends StatelessWidget {
  const ArrivalProgress({
    super.key,
    required this.current,
    required this.total,
  });

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: NeoMotion.ample,
              curve: NeoMotion.enter,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NeoRadius.pill),
                color: i <= current ? null : p.line,
                gradient: i <= current ? p.signatureCourte : null,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Un titre de l'arrivée : grand, rond, et qui se dit en une phrase.
class ArrivalTitle extends StatelessWidget {
  const ArrivalTitle(this.text, {super.key, this.gradient = false});

  final String text;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(
      fontFamily: NeoType.display,
      fontWeight: FontWeight.w600,
      fontSize: 34,
      height: 1.1,
      color: p.ink,
    );
    final title = Text(text, textAlign: TextAlign.center, style: style);
    if (!gradient) return title;
    return ShaderMask(
      shaderCallback: (r) => p.signature.createShader(r),
      child: title,
    );
  }
}

/// La pastille « démo » : ce qui est simulé le dit.
class DemoChip extends StatelessWidget {
  const DemoChip(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(NeoRadius.pill),
        border: Border.all(color: p.warm.withValues(alpha: 0.7)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: p.warm,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Le dégradé d'une tuile de Drop simulée : pris dans la palette, tourné
/// différemment selon le rang — jamais deux voisines pareilles.
Gradient demoTileGradient(NeoPalette p, int index) {
  final sets = [
    [p.cool, p.action],
    [p.action, p.warm],
    [p.warm, p.cool],
    [p.cool, p.warm],
  ];
  final colors = sets[index % sets.length];
  final angle = (index * 0.9) % (2 * math.pi);
  return LinearGradient(
    colors: [colors[0], colors[1].withValues(alpha: 0.85)],
    transform: GradientRotation(angle),
  );
}
