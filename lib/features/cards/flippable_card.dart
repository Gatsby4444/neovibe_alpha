import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Carte Mono : face unique, PAS de retournement, mais le jeu d'angle reste
/// (consigne Jay 2026-07-12) — le doigt incline la carte dans l'espace
/// (rotations X/Y bornées), elle revient à plat au relâchement. Le tap ne
/// fait rien : il n'y a pas de deuxième face.
class TiltableCard extends StatefulWidget {
  const TiltableCard({super.key, required this.child});

  final Widget child;

  @override
  State<TiltableCard> createState() => _TiltableCardState();
}

class _TiltableCardState extends State<TiltableCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  )..addListener(_onTick);

  /// Inclinaisons courantes (radians), bornées pour rester subtiles.
  double _tiltX = 0;
  double _tiltY = 0;
  double _startTiltX = 0;
  double _startTiltY = 0;

  static const _maxTilt = 0.32;

  void _onTick() {
    final t = Curves.easeOutCubic.transform(_controller.value);
    setState(() {
      _tiltX = lerpDouble(_startTiltX, 0, t)!;
      _tiltY = lerpDouble(_startTiltY, 0, t)!;
    });
  }

  void _onPanStart(DragStartDetails details) => _controller.stop();

  void _onPanUpdate(DragUpdateDetails details) {
    final size = context.size ?? const Size(300, 400);
    setState(() {
      _tiltY = (_tiltY + details.delta.dx / size.width * 1.4).clamp(
        -_maxTilt,
        _maxTilt,
      );
      _tiltX = (_tiltX - details.delta.dy / size.height * 1.4).clamp(
        -_maxTilt,
        _maxTilt,
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _startTiltX = _tiltX;
    _startTiltY = _tiltY;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012) // même perspective que FlippableCard
      ..rotateX(_tiltX)
      ..rotateY(_tiltY);

    return GestureDetector(
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Transform(
        alignment: Alignment.center,
        transform: matrix,
        child: widget.child,
      ),
    );
  }
}

/// Carte retournable "comme une vraie carte dans l'espace" (consigne Jay) :
/// - le doigt entraîne la carte : rotation Y continue + légère inclinaison X,
/// - au relâchement, un angle suffisant ou un swipe (vélocité) termine le
///   retournement ; sinon la carte revient à plat sur sa face courante,
/// - un tap déclenche un retournement animé complet.
class FlippableCard extends StatefulWidget {
  const FlippableCard({
    super.key,
    required this.front,
    required this.back,
    this.onSideChanged,
    this.invertDrag = false,
  });

  final Widget front;
  final Widget back;

  /// Appelé quand la face visible change (true = recto).
  final ValueChanged<bool>? onSideChanged;

  /// Inverse le sens de rotation entraîné par le doigt (préférence utilisateur).
  final bool invertDrag;

  @override
  State<FlippableCard> createState() => _FlippableCardState();
}

class _FlippableCardState extends State<FlippableCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Rotation Y cumulée (radians). Multiple pair de π = recto, impair = verso.
  double _angle = 0;

  /// Inclinaison X légère pendant le geste (retour à 0 au relâchement).
  double _tilt = 0;

  double _startAngle = 0;
  double _targetAngle = 0;
  double _startTilt = 0;
  bool _lastReportedFront = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..addListener(_onTick);
  }

  void _onTick() {
    final t = Curves.easeOutCubic.transform(_controller.value);
    setState(() {
      _angle = lerpDouble(_startAngle, _targetAngle, t)!;
      _tilt = lerpDouble(_startTilt, 0, t)!;
    });
    _reportSideIfChanged();
  }

  bool get _showFront {
    // cos > 0 : on voit le recto ; la perspective inverse la face au-delà de π/2
    return math.cos(_angle) >= 0;
  }

  void _reportSideIfChanged() {
    if (_showFront != _lastReportedFront) {
      _lastReportedFront = _showFront;
      widget.onSideChanged?.call(_lastReportedFront);
    }
  }

  void _onPanStart(DragStartDetails details) {
    _controller.stop();
  }

  double get _dragSign => widget.invertDrag ? -1.0 : 1.0;

  void _onPanUpdate(DragUpdateDetails details) {
    final size = context.size ?? const Size(300, 400);
    setState(() {
      // Un glissement sur toute la largeur ≈ un demi-tour
      _angle += _dragSign * details.delta.dx / size.width * math.pi;
      // Inclinaison légère qui suit le doigt, bornée pour rester subtile
      _tilt = (_tilt - details.delta.dy / size.height * 0.6).clamp(-0.22, 0.22);
    });
    _reportSideIfChanged();
  }

  void _onPanEnd(DragEndDetails details) {
    final size = context.size ?? const Size(300, 400);
    // Le swipe pousse la carte dans son sens : on projette l'angle un court
    // instant dans le futur avec la vélocité du geste, puis on retombe sur la
    // face (multiple de π) la plus proche de cette projection.
    final angularVelocity =
        _dragSign * details.velocity.pixelsPerSecond.dx / size.width * math.pi;
    final projected = _angle + angularVelocity * 0.12;
    _settleTo((projected / math.pi).round() * math.pi);
  }

  /// Tap : retournement animé complet vers la face opposée.
  void _flip() {
    _controller.stop();
    _settleTo(((_angle / math.pi).round() + 1) * math.pi);
  }

  void _settleTo(double target) {
    _startAngle = _angle;
    _targetAngle = target.toDouble();
    _startTilt = _tilt;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012) // perspective : le mix 2D/3D
      ..rotateX(_tilt)
      ..rotateY(_angle);

    return GestureDetector(
      onTap: _flip,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Transform(
        alignment: Alignment.center,
        transform: matrix,
        child: _showFront
            ? widget.front
            // Le verso est pré-retourné pour ne pas apparaître en miroir
            : Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(math.pi),
                child: widget.back,
              ),
      ),
    );
  }
}
