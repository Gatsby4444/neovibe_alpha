import 'dart:math' as math;
import 'dart:ui';

/// Ce que fait un geste à deux doigts sur la carte.
enum TwoFingerKind {
  /// Pas encore décidé : les doigts n'ont pas assez bougé.
  undecided,

  /// Les doigts se rapprochent ou s'écartent.
  zoom,

  /// Les doigts tournent l'un autour de l'autre.
  rotate,

  /// Les doigts montent ou descendent ENSEMBLE.
  tilt,
}

/// Ce que le geste demande à la caméra, par rapport au DÉBUT du geste.
class TwoFingerDelta {
  const TwoFingerDelta({
    required this.kind,
    this.zoomBy = 0,
    this.rotateByDeg = 0,
    this.tiltByPx = 0,
  });

  final TwoFingerKind kind;

  /// Niveaux de zoom à ajouter (1 = deux fois plus près).
  final double zoomBy;

  /// Degrés dont les doigts ont tourné (sens des aiguilles d'une montre > 0).
  final double rotateByDeg;

  /// De combien les doigts sont montés ensemble, en points (vers le haut > 0).
  final double tiltByPx;
}

/// **Reconnaître un geste à deux doigts, comme Google Maps** (2026-09-26).
///
/// ## 🔴 Pourquoi on ne laisse plus faire Mapbox
///
/// Lu dans son code (maps-gestures 11.31.1, mapbox-android-gestures
/// 0.10.0) : quatre détecteurs partent EN MÊME TEMPS, et le premier qui
/// démarre gagne. Le zoom part dès que l'écart des doigts change un peu
/// vite, la rotation dès 3°, alors que l'inclinaison attend 16 dp de course
/// verticale, doigts côte à côte à 45° près — et Mapbox la déclare
/// incompatible avec le zoom et la rotation
/// (`initializeGesturesManager`). Deux doigts qui montent ensemble ne
/// gardent jamais exactement leur écart ni leur angle : le zoom ou la
/// rotation gagnait presque toujours, et l'inclinaison devenait impossible
/// pour tout le reste du geste. Constaté par Jay, deux fois.
///
/// ## Ce qu'on fait à la place : le mouvement qui DOMINE
///
/// Tant que les doigts n'ont pas parcouru [slop], rien ne se décide. Puis
/// on compare trois mouvements, tous en points à l'écran :
///
/// - **zoom** : de combien l'écart entre les doigts a changé ;
/// - **rotation** : l'arc parcouru par les doigts en tournant ;
/// - **inclinaison** : la montée (ou descente) COMMUNE — celle du doigt qui
///   a le moins bougé verticalement, et seulement si les deux vont dans le
///   même sens.
///
/// Le plus grand l'emporte, et le geste s'y tient jusqu'au bout (on ne
/// passe pas d'une inclinaison à un zoom en cours de route). Comme Google
/// Maps, une rotation zoome aussi, et un zoom se met à tourner si l'angle
/// dépasse [rotateJoinDeg] — assez pour qu'un pincement un peu de travers
/// ne fasse pas pivoter la carte.
class TwoFingerGesture {
  TwoFingerGesture(this._a0, this._b0);

  /// Distance à parcourir avant de décider, en points.
  static const slop = 10.0;

  /// Au-delà de cet angle, un zoom tourne aussi.
  static const rotateJoinDeg = 20.0;

  final Offset _a0, _b0;
  TwoFingerKind _kind = TwoFingerKind.undecided;

  /// L'angle au moment où un zoom s'est mis à tourner : la rotation part de
  /// là, sans à-coup de [rotateJoinDeg] d'un coup.
  double? _rotationDepuis;

  TwoFingerKind get kind => _kind;

  /// Le point entre les deux doigts au début : c'est autour de lui qu'on
  /// zoome et qu'on tourne.
  Offset get startFocal => (_a0 + _b0) / 2;

  /// Les doigts sont maintenant en [a] et [b] (dans le même ordre qu'au
  /// début).
  TwoFingerDelta update(Offset a, Offset b) {
    final da = a - _a0, db = b - _b0;
    final span0 = (_b0 - _a0).distance;
    final span = (b - a).distance;
    final angle = _angleDeg(b - a) - _angleDeg(_b0 - _a0);
    final rot = ((angle + 540) % 360) - 180;

    if (_kind == TwoFingerKind.undecided) {
      if (math.max(da.distance, db.distance) < slop) {
        return const TwoFingerDelta(kind: TwoFingerKind.undecided);
      }
      final zoomPx = (span - span0).abs();
      final rotatePx = rot.abs() * math.pi / 180 * span0 / 2;
      final ensemble = da.dy.sign == db.dy.sign && da.dy != 0;
      final tiltPx = ensemble ? math.min(da.dy.abs(), db.dy.abs()) : 0.0;
      if (tiltPx >= zoomPx && tiltPx >= rotatePx) {
        _kind = TwoFingerKind.tilt;
      } else if (rotatePx > zoomPx) {
        _kind = TwoFingerKind.rotate;
      } else {
        _kind = TwoFingerKind.zoom;
      }
    }

    final zoomBy = span0 > 0 && span > 0
        ? math.log(span / span0) / math.ln2
        : 0.0;
    switch (_kind) {
      case TwoFingerKind.tilt:
        return TwoFingerDelta(kind: _kind, tiltByPx: -(da.dy + db.dy) / 2);
      case TwoFingerKind.rotate:
        return TwoFingerDelta(kind: _kind, zoomBy: zoomBy, rotateByDeg: rot);
      case TwoFingerKind.zoom:
        if (_rotationDepuis == null && rot.abs() > rotateJoinDeg) {
          _rotationDepuis = rot;
        }
        final depuis = _rotationDepuis;
        return TwoFingerDelta(
          kind: _kind,
          zoomBy: zoomBy,
          rotateByDeg: depuis == null ? 0 : rot - depuis,
        );
      case TwoFingerKind.undecided:
        return const TwoFingerDelta(kind: TwoFingerKind.undecided);
    }
  }

  static double _angleDeg(Offset v) => math.atan2(v.dy, v.dx) * 180 / math.pi;
}
