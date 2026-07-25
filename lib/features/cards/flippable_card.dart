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
    this.onSideSettled,
    this.invertDrag = false,
    this.dragAxis,
    this.onTap,
  });

  final Widget front;
  final Widget back;

  /// Axe du geste de retournement.
  /// - `null` (défaut) : geste libre (pan), comportement du viewer plein écran.
  /// - `Axis.horizontal` / `Axis.vertical` : le geste est contraint à cet axe,
  ///   et la carte tourne autour de l'axe correspondant. Indispensable dans une
  ///   liste défilante : un `pan` capterait le défilement (mini-cards de la
  ///   bibliothèque, consigne Jay 2026-07-25).
  final Axis? dragAxis;

  /// Si fourni, le tap déclenche CECI au lieu de retourner la carte — le
  /// retournement ne se fait plus qu'au swipe (mini-cards : « le geste qui
  /// swipe c'est le swipe, le geste qui ouvre c'est le clic »).
  final VoidCallback? onTap;

  /// Appelé quand la face visible change (true = recto) — y compris pendant
  /// le geste (peut osciller si le doigt fait des allers-retours).
  final ValueChanged<bool>? onSideChanged;

  /// Appelé quand la carte se POSE sur une face à la fin de l'animation
  /// (tap ou relâchement) — c'est le signal fiable d'un vrai retournement,
  /// utilisé pour la mécanique « retourner = couper court » (consigne Jay).
  final ValueChanged<bool>? onSideSettled;

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

  bool get _vertical => widget.dragAxis == Axis.vertical;

  void _onPanUpdate(DragUpdateDetails details) {
    final size = context.size ?? const Size(300, 400);
    setState(() {
      if (_vertical) {
        // Un glissement sur toute la hauteur ≈ un demi-tour (doigt vers le
        // haut = le haut de la carte part vers l'arrière).
        _angle += _dragSign * -details.delta.dy / size.height * math.pi;
      } else {
        // Un glissement sur toute la largeur ≈ un demi-tour
        _angle += _dragSign * details.delta.dx / size.width * math.pi;
        // Inclinaison légère qui suit le doigt, bornée pour rester subtile
        // (uniquement en geste libre : sur un axe contraint il n'y a pas de
        // seconde composante à suivre).
        if (widget.dragAxis == null) {
          _tilt = (_tilt - details.delta.dy / size.height * 0.6).clamp(
            -0.22,
            0.22,
          );
        }
      }
    });
    _reportSideIfChanged();
  }

  void _onPanEnd(DragEndDetails details) {
    final size = context.size ?? const Size(300, 400);
    // Le swipe pousse la carte dans son sens : on projette l'angle un court
    // instant dans le futur avec la vélocité du geste, puis on retombe sur la
    // face (multiple de π) la plus proche de cette projection.
    final angularVelocity = _vertical
        ? _dragSign *
              -details.velocity.pixelsPerSecond.dy /
              size.height *
              math.pi
        : _dragSign *
              details.velocity.pixelsPerSecond.dx /
              size.width *
              math.pi;
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
    // Le TickerFuture ne se résout que si l'animation va au bout : un
    // nouveau geste qui interrompt la pose ne déclenche PAS onSideSettled.
    _controller.forward(from: 0).whenComplete(() {
      if (mounted) widget.onSideSettled?.call(_showFront);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012); // perspective : le mix 2D/3D
    if (_vertical) {
      matrix.rotateX(_angle);
    } else {
      matrix
        ..rotateX(_tilt)
        ..rotateY(_angle);
    }

    final card = Transform(
      alignment: Alignment.center,
      transform: matrix,
      child: _showFront
          ? widget.front
          // Le verso est pré-retourné pour ne pas apparaître en miroir, sur
          // le même axe que le retournement.
          : Transform(
              alignment: Alignment.center,
              transform: _vertical
                  ? (Matrix4.identity()..rotateX(math.pi))
                  : (Matrix4.identity()..rotateY(math.pi)),
              child: widget.back,
            ),
    );

    // Sur un axe contraint, on utilise les reconnaisseurs d'axe : le geste
    // perpendiculaire reste disponible pour le défilement de la liste.
    return switch (widget.dragAxis) {
      Axis.horizontal => GestureDetector(
        onTap: widget.onTap ?? _flip,
        onHorizontalDragStart: _onPanStart,
        onHorizontalDragUpdate: _onPanUpdate,
        onHorizontalDragEnd: _onPanEnd,
        child: card,
      ),
      Axis.vertical => GestureDetector(
        onTap: widget.onTap ?? _flip,
        onVerticalDragStart: _onPanStart,
        onVerticalDragUpdate: _onPanUpdate,
        onVerticalDragEnd: _onPanEnd,
        child: card,
      ),
      null => GestureDetector(
        onTap: widget.onTap ?? _flip,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: card,
      ),
    };
  }
}
