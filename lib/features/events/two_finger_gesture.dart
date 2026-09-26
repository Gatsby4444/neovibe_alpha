import 'dart:math' as math;
import 'dart:ui';

/// Ce que fait un geste à deux doigts sur la carte.
enum TwoFingerKind {
  /// Pas encore décidé : les doigts n'ont pas assez bougé. La carte suit
  /// les doigts (déplacement), comme Google Maps.
  undecided,

  /// Les doigts glissent ENSEMBLE : la carte se déplace. Peut devenir une
  /// inclinaison si le mouvement vertical se prolonge ([TwoFingerGesture.tiltAfterPx]).
  pan,

  /// Les doigts se rapprochent ou s'écartent : zoom SEUL, jusqu'au bout.
  zoom,

  /// Les doigts tournent en sens opposés : rotation, ET zoom si l'écart
  /// change en même temps.
  rotate,

  /// Les doigts montent ou descendent ensemble, assez longtemps : l'angle
  /// de vue change, la carte ne se déplace plus.
  tilt;

  /// La carte peut-elle suivre les doigts (déplacement) ? Oui tant qu'on ne
  /// zoome, ne tourne ni n'incline.
  bool get pans => this == undecided || this == pan;
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

  /// De combien les doigts sont montés ensemble DEPUIS que l'inclinaison a
  /// pris la main, en points (vers le haut > 0).
  final double tiltByPx;
}

/// **Reconnaître un geste à deux doigts, avec la hiérarchie de Google Maps**
/// (relevée par Jay sur son téléphone, 2026-09-26).
///
/// ## Ce que fait Google Maps — et donc ce qu'on fait
///
/// 1. **Commencer par zoomer, c'est zoomer seulement** : ni rotation, ni
///    inclinaison, jusqu'à ce qu'on lève les doigts.
/// 2. **Deux doigts qui glissent ensemble déplacent d'abord la carte.** Si le
///    mouvement VERTICAL se prolonge (≈ 4 mm, [tiltAfterPx]), le déplacement
///    s'arrête et c'est l'angle de vue qui change. En butée d'angle, on voit
///    donc la carte glisser de quelques millimètres, puis plus rien.
/// 3. **Deux doigts en sens opposés tournent la carte** — et zooment en
///    même temps si leur écart change.
///
/// Le premier mouvement qui dépasse [slop] décide : écart qui change
/// (zoom), arc parcouru en tournant (rotation), ou glissement commun
/// (déplacement). Ensuite on n'en change plus — sauf le déplacement, qui
/// devient une inclinaison (règle 2).
///
/// ## 🔴 Pourquoi on ne laisse plus faire Mapbox
///
/// Lu dans son code (maps-gestures 11.31.1, mapbox-android-gestures
/// 0.10.0) : ses détecteurs se disputent le geste, le premier parti gagne,
/// et l'inclinaison — déclarée incompatible avec le zoom et la rotation —
/// perdait presque toujours. Mapbox ne fait plus ici que le DÉPLACEMENT
/// (à un doigt, ou à deux tant que [TwoFingerKind.pans]).
class TwoFingerGesture {
  TwoFingerGesture(this._a0, this._b0);

  /// Distance à parcourir avant de décider, en points (~1,3 mm).
  static const slop = 8.0;

  /// Montée commune au-delà de laquelle un déplacement devient une
  /// inclinaison, en points (~4 mm, relevé par Jay sur Google Maps).
  static const tiltAfterPx = 25.0;

  final Offset _a0, _b0;
  TwoFingerKind _kind = TwoFingerKind.undecided;

  /// La montée commune au moment où l'inclinaison a pris la main : on
  /// incline à partir de là, sans à-coup.
  double _tiltDepuis = 0;

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
    final commun = (da + db) / 2;

    if (_kind == TwoFingerKind.undecided) {
      final zoomPx = (span - span0).abs();
      final rotatePx = rot.abs() * math.pi / 180 * span0 / 2;
      // Glissement commun : les deux doigts vont dans le même sens.
      final ensemble = da.dx * db.dx + da.dy * db.dy > 0;
      final glissePx = ensemble ? commun.distance : 0.0;
      final plus = math.max(zoomPx, math.max(rotatePx, glissePx));
      if (plus < slop) {
        return const TwoFingerDelta(kind: TwoFingerKind.undecided);
      }
      _kind = plus == glissePx
          ? TwoFingerKind.pan
          : plus == rotatePx
          ? TwoFingerKind.rotate
          : TwoFingerKind.zoom;
    }

    // Règle 2 : un déplacement dont la part VERTICALE se prolonge devient
    // une inclinaison.
    if (_kind == TwoFingerKind.pan &&
        commun.dy.abs() >= tiltAfterPx &&
        commun.dy.abs() >= commun.dx.abs()) {
      _kind = TwoFingerKind.tilt;
      _tiltDepuis = commun.dy;
    }

    final zoomBy = span0 > 0 && span > 0
        ? math.log(span / span0) / math.ln2
        : 0.0;
    return switch (_kind) {
      TwoFingerKind.zoom => TwoFingerDelta(kind: _kind, zoomBy: zoomBy),
      TwoFingerKind.rotate => TwoFingerDelta(
        kind: _kind,
        zoomBy: zoomBy,
        rotateByDeg: rot,
      ),
      TwoFingerKind.tilt => TwoFingerDelta(
        kind: _kind,
        tiltByPx: -(commun.dy - _tiltDepuis),
      ),
      _ => TwoFingerDelta(kind: _kind),
    };
  }

  static double _angleDeg(Offset v) => math.atan2(v.dy, v.dx) * 180 / math.pi;
}
