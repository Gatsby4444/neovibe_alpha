import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

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
    this.target,
    this.onStart,
    this.course = 0.32,
    this.seuil = 0.45,
  });

  final Widget child;
  final VoidCallback onClose;

  /// **Où se refermer** : la boîte, en coordonnées globales, de la cellule
  /// d'où l'écran est venu — lue à chaque image pendant le pincement. Nulle
  /// (ou rendant `null`) : la forme se rétracte au centre, comme avant.
  ///
  /// ⚠️ Cet écran est supposé occuper **tout** l'écran, à l'origine : les
  /// coordonnées globales de la cible sont donc les siennes. C'est le cas
  /// des deux plein-écrans (un `Scaffold` sans barre, sans `SafeArea`).
  final Rect? Function()? target;

  /// Le pincement commence : l'occasion, pour l'écran, de demander au
  /// dessous de **montrer** la cellule visée avant qu'on la vise.
  final VoidCallback? onStart;

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
        if (_doigts.length == 2) {
          // Deux doigts posés : un pincement peut commencer — le dessous
          // est prévenu tout de suite, pour avoir le temps de se poser.
          _ecartInitial = _ecart();
          widget.onStart?.call();
        }
      },
      onPointerMove: (e) {
        if (!_doigts.containsKey(e.pointer)) return;
        _doigts[e.pointer] = e.position;
        _bouge();
      },
      onPointerUp: (e) => _leve(e.pointer),
      onPointerCancel: (e) => _leve(e.pointer),
      // ⚠️ **Les deux enveloppes sont TOUJOURS là** — échelle 1 et découpage
      // désactivé tant qu'on ne pince pas. Jusqu'au 2026-09-19, l'écran
      // n'était emballé qu'à partir du premier pincement : pour Flutter,
      // « l'écran » et « l'écran dans deux enveloppes » sont deux arbres, et
      // le second était RECONSTRUIT de zéro — la liste des Vibes repartait à
      // sa page de départ (la forme qui rétrécit montrait la Vibe d'où le
      // plein écran avait été ouvert, pas celle qu'on regardait), et le
      // lecteur d'un Flow repartait du début. La structure ne dépend pas
      // d'un état — la même règle que la carte retournable, le même jour.
      child: _vise(
        ClipPath(
          clipBehavior: _t == 0 ? Clip.none : Clip.antiAlias,
          clipper: RetractionClipper(math.min(_t, 1)),
          child: widget.child,
        ),
      ),
    );
  }

  /// La forme **glisse vers la cellule** et prend sa largeur, à mesure du
  /// pincement (Jay, 2026-09-19 : *« que le plein écran redevienne la card, à
  /// sa place »*). Sans cible : la rétraction au centre, un souffle d'échelle.
  Widget _vise(Widget child) {
    final cible = _t > 0 ? widget.target?.call() : null;
    if (cible == null) {
      return Transform.scale(scale: 1 - 0.12 * _t, child: child);
    }
    final ecran = MediaQuery.sizeOf(context);
    final t = math.min(_t, 1.0);
    final echelle = lerpDouble(1, cible.width / ecran.width, t)!;
    final centre = Offset.lerp(ecran.center(Offset.zero), cible.center, t)!;
    // `alignment: center` : l'échelle se fait autour du centre de l'écran, et
    // la translation amène ce centre sur celui de la cellule.
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.translationValues(
        centre.dx - ecran.width / 2,
        centre.dy - ecran.height / 2,
        0,
      )..scaleByDouble(echelle, echelle, 1, 1),
      child: child,
    );
  }
}
