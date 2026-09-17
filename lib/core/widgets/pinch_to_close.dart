import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'retraction.dart';

/// **Dézoomer à deux doigts ferme l'écran** (Jay, 2026-09-17), et l'écran
/// suit le geste : il rétrécit et se referme en heptagone aux côtés creusés
/// (voir [formeRetractee]) à mesure que les doigts se rapprochent.
///
/// ### Pourquoi un `Listener` et pas un reconnaisseur de pincement
///
/// `ScaleGestureRecognizer` **accepte aussi sur le déplacement du point
/// focal** — donc avec un seul doigt, exactement comme un pan (vérifié dans
/// `gestures/scale.dart`, `_advanceStateMachine`, le 2026-09-17). Posé
/// au-dessus du plein écran, il serait entré dans l'arène contre le
/// retournement de la carte et le défilement d'une Vibe à l'autre, et aurait
/// volé des gestes à un doigt.
///
/// Un [Listener] ne participe pas à l'arène : il **regarde** les pointeurs
/// sans les prendre. Le pincement est donc calculé à la main — écart entre
/// deux doigts, rapporté à l'écart de départ — et **rien n'est enlevé à
/// personne** : la carte se retourne et le fil défile comme avant.
///
/// ⚠️ Le premier doigt peut avoir déjà commencé à incliner la carte quand le
/// second se pose. C'est assumé : la carte revient d'elle-même à plat, et un
/// pincement franc démarre dans la foulée.
class PinchToClose extends StatefulWidget {
  const PinchToClose({
    super.key,
    required this.child,
    required this.onClose,
    this.course = 0.32,
    this.seuil = 0.45,
  });

  final Widget child;
  final VoidCallback onClose;

  /// De combien les doigts doivent se rapprocher pour aller de 0 à 1 : 0,32
  /// = un tiers de l'écart de départ.
  final double course;

  /// Au-delà de cette avancée, on ferme au relâchement.
  final double seuil;

  @override
  State<PinchToClose> createState() => _PinchToCloseState();
}

class _PinchToCloseState extends State<PinchToClose>
    with SingleTickerProviderStateMixin {
  /// Les doigts posés, et où ils sont.
  final _doigts = <int, Offset>{};

  /// L'écart entre les deux premiers doigts au moment où ils se sont trouvés.
  double? _ecartInitial;

  /// L'avancée du geste, 0 … 1.
  var _t = 0.0;
  var _ferme = false;

  late final AnimationController _retour = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(() => setState(() => _t = _tween.evaluate(_retour)));
  var _tween = Tween<double>(begin: 0, end: 0);

  @override
  void dispose() {
    _retour.dispose();
    super.dispose();
  }

  double? _ecart() {
    if (_doigts.length < 2) return null;
    final p = _doigts.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _bouge() {
    final e = _ecart();
    if (e == null) return;
    _ecartInitial ??= e;
    if (_ecartInitial! < 24) return; // deux doigts collés : pas un pincement
    _retour.stop();
    final rapport = e / _ecartInitial!;
    // On ne réagit qu'au DÉ-zoom : écarter les doigts ne fait rien.
    final avance = ((1 - rapport) / widget.course).clamp(0.0, 1.0);
    if (avance != _t) setState(() => _t = avance);
  }

  void _leve(int pointeur) {
    _doigts.remove(pointeur);
    if (_doigts.length >= 2 || _ferme) return;
    _ecartInitial = null;
    if (_t <= 0) return;
    if (_t >= widget.seuil) {
      _ferme = true;
      _animer(1).whenComplete(() {
        if (mounted) widget.onClose();
      });
    } else {
      _animer(0);
    }
  }

  TickerFuture _animer(double cible) {
    _tween = Tween(begin: _t, end: cible);
    return _retour.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // On regarde tous les pointeurs, y compris ceux qu'un autre geste a
      // déjà pris : c'est le propre d'un Listener.
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (e) {
        _doigts[e.pointer] = e.position;
        if (_doigts.length == 2) _ecartInitial = _ecart();
      },
      onPointerMove: (e) {
        if (!_doigts.containsKey(e.pointer)) return;
        _doigts[e.pointer] = e.position;
        _bouge();
      },
      onPointerUp: (e) => _leve(e.pointer),
      onPointerCancel: (e) => _leve(e.pointer),
      child: _t == 0
          ? widget.child
          : Transform.scale(
              // La forme se rétracte déjà beaucoup : l'échelle n'ajoute
              // qu'un souffle.
              scale: 1 - 0.12 * _t,
              child: ClipPath(
                clipper: RetractionClipper(math.min(_t, 1)),
                child: widget.child,
              ),
            ),
    );
  }
}
