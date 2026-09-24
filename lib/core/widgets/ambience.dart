import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion.dart';
import '../theme.dart';

/// **Les lumières de soirée** : deux taches de couleur qui dérivent lentement
/// sur le fond, comme les lumières d'un bar vues depuis la rue.
///
/// Née dans l'arrivée en soirée (test, 2026-09-24), étendue à toute l'app par
/// l'identité **Vice6** le même jour (`MaterialApp.builder`, voir `app.dart`).
/// **Un seul widget pour les deux** : l'écran de test et l'app ne peuvent pas
/// diverger.
///
/// ## ⚠️ Le coût, parce que ce fond est derrière TOUS les écrans
///
/// - **15 images par seconde, pas 60.** Un tour dure 14 s : à cette lenteur,
///   un pas de 66 ms déplace les lumières de moins d'un pixel — l'œil ne voit
///   pas la différence, la batterie si. Pas d'`AnimationController` : il
///   redessinerait à chaque image de l'écran.
/// - **Arrêt hors du premier plan** : l'horloge ne tourne que si l'app est
///   `resumed`.
/// - **`RepaintBoundary`** : ce qui bouge ne fait redessiner que le fond, jamais
///   l'écran posé dessus.
///
/// 🔴 Calculé, pas mesuré (règle « mesurer le coût ») — à vérifier sur le
/// téléphone de Jay si la batterie ou la fluidité s'en ressentent.
class NeoAmbience extends StatefulWidget {
  const NeoAmbience({super.key, required this.child, this.intensity = 1});

  final Widget child;

  /// 0 = éteint, 1 = la soirée ; au-delà, plus vif (entrée dans la soirée).
  final double intensity;

  /// La force « dans la soirée » : celle du dernier écran de l'arrivée
  /// (« Tu es dedans »), et celle de toute l'app sous Vice6 — Jay,
  /// 2026-09-24 : *« mets la version plus vive dans toute l'app »*.
  static const soiree = 1.4;

  /// La durée d'un tour complet.
  static const period = Duration(seconds: 14);

  /// Le pas de l'horloge (≈ 15 images/s).
  static const step = Duration(milliseconds: 66);

  @override
  State<NeoAmbience> createState() => _NeoAmbienceState();
}

class _NeoAmbienceState extends State<NeoAmbience> with WidgetsBindingObserver {
  final _phase = ValueNotifier<double>(0);
  final _clock = Stopwatch();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    if (_timer != null) return;
    _clock.start();
    _timer = Timer.periodic(NeoAmbience.step, (_) {
      final period = NeoAmbience.period.inMicroseconds;
      _phase.value = (_clock.elapsedMicroseconds % period) / period;
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: p.ground,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: widget.intensity),
                duration: const Duration(milliseconds: 900),
                curve: NeoMotion.enter,
                builder: (context, intensity, _) => CustomPaint(
                  painter: _AmbiencePainter(
                    phase: _phase,
                    colorA: p.cool.withValues(alpha: 0.30 * intensity),
                    colorB: p.action.withValues(alpha: 0.26 * intensity),
                  ),
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _AmbiencePainter extends CustomPainter {
  _AmbiencePainter({
    required this.phase,
    required this.colorA,
    required this.colorB,
  }) : super(repaint: phase);

  final ValueNotifier<double> phase;
  final Color colorA;
  final Color colorB;

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase.value * 2 * math.pi;
    final a = Alignment(-0.7 + 0.25 * math.sin(t), -0.8);
    final b = Alignment(0.8, 0.6 + 0.2 * math.cos(t));
    final r = size.longestSide * 0.62;
    for (final (at, color) in [(a, colorA), (b, colorB)]) {
      final c = at.alongSize(size);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AmbiencePainter old) =>
      old.phase != phase || old.colorA != colorA || old.colorB != colorB;
}
