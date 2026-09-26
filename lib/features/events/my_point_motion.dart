import 'dart:math' as math;

import '../../core/location/distance.dart';

/// Ce que la carte doit dessiner de moi, à un instant.
class MyPointFrame {
  const MyPointFrame({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.heading,
  });

  final double lat;
  final double lon;

  /// Le rayon du halo d'incertitude, en mètres.
  final double accuracy;

  /// La direction affichée, 0..360 ; nulle = pas de flèche.
  final double? heading;
}

/// **Le mouvement de mon point** (2026-09-25, demande de Jay : *« voir le
/// déplacement en temps réel, progressif, au lieu de voir le point se
/// téléporter »*).
///
/// C'est une décision d'AFFICHAGE, donc elle vit ici et pas dans ce qui
/// mesure : la position arrive par à-coups (un relevé par seconde au mieux),
/// la boussole une quinzaine de fois par seconde et en tremblant. Ce calcul
/// ne touche à aucune mesure ; il dit seulement où dessiner, entre deux.
///
/// - **La position glisse** d'un relevé au suivant, en autant de temps qu'il
///   en a séparé les deux derniers (borné) : le point avance à la cadence où
///   il est mesuré, sans jamais rester figé ni courir devant.
/// - **Un saut de plus de [sautM] ne glisse pas** : c'est un point faux
///   corrigé (précision retrouvée, sortie d'un tunnel), pas un déplacement —
///   le faire glisser montrerait un trajet qui n'a pas eu lieu.
/// - **La flèche tourne en douceur**, par le plus court chemin (de 350° à
///   10° : 20°, jamais 340°).
///
/// Sans horloge propre : chaque appel reçoit `now`, ce qui le rend testable
/// (`test/my_point_motion_test.dart`).
class MyPointMotion {
  /// Au-delà, on saute au lieu de glisser.
  static const sautM = 300.0;

  /// Temps de réponse de la flèche : elle a fait ~63 % du chemin en ce temps.
  static const reponseFleche = Duration(milliseconds: 150);

  static const _glisseMin = Duration(milliseconds: 300);
  static const _glisseMax = Duration(milliseconds: 1500);

  double? _deLat, _deLon, _deAcc;
  double? _versLat, _versLon, _versAcc;
  DateTime? _debut;
  Duration _duree = Duration.zero;
  DateTime? _dernierReleve;

  double? _cap;
  double? _capVise;
  DateTime? _dernierPas;

  /// Un nouveau relevé.
  void setFix(double lat, double lon, double accuracy, DateTime now) {
    final ici = _positionAt(now);
    if (ici == null || metersBetween(ici.$1, ici.$2, lat, lon) > sautM) {
      _deLat = lat;
      _deLon = lon;
      _deAcc = accuracy;
      _duree = Duration.zero;
    } else {
      _deLat = ici.$1;
      _deLon = ici.$2;
      _deAcc = ici.$3;
      final depuis = _dernierReleve == null
          ? _glisseMax
          : now.difference(_dernierReleve!);
      _duree = depuis < _glisseMin
          ? _glisseMin
          : depuis > _glisseMax
          ? _glisseMax
          : depuis;
    }
    _versLat = lat;
    _versLon = lon;
    _versAcc = accuracy;
    _debut = now;
    _dernierReleve = now;
  }

  /// Une nouvelle mesure de boussole ; nulle = plus de flèche.
  void setHeading(double? degrees) {
    _capVise = degrees;
    if (degrees == null) _cap = null;
  }

  /// Où dessiner à [now] — et fait avancer la flèche. Nul avant le premier
  /// relevé.
  MyPointFrame? frameAt(DateTime now) {
    final ici = _positionAt(now);
    if (ici == null) return null;
    return MyPointFrame(
      lat: ici.$1,
      lon: ici.$2,
      accuracy: ici.$3,
      heading: _avancerCap(now),
    );
  }

  /// **Où mon point est dessiné** à [now] — ce que vise « recentrer ». Ne
  /// fait pas avancer la flèche. Nul avant le premier relevé.
  ({double lat, double lon})? positionAt(DateTime now) {
    final ici = _positionAt(now);
    return ici == null ? null : (lat: ici.$1, lon: ici.$2);
  }

  /// La position affichée à [now], sans toucher à la flèche.
  (double, double, double)? _positionAt(DateTime now) {
    if (_versLat == null) return null;
    final t = _duree == Duration.zero
        ? 1.0
        : (now.difference(_debut!).inMicroseconds / _duree.inMicroseconds)
              .clamp(0.0, 1.0);
    // Démarrage et arrivée adoucis : un point qui part et s'arrête net a
    // l'air de sauter quand même.
    final e = t * t * (3 - 2 * t);
    return (
      _deLat! + (_versLat! - _deLat!) * e,
      _deLon! + (_versLon! - _deLon!) * e,
      _deAcc! + (_versAcc! - _deAcc!) * e,
    );
  }

  double? _avancerCap(DateTime now) {
    final vise = _capVise;
    final dt = _dernierPas == null
        ? 0.0
        : _secondes(now.difference(_dernierPas!));
    _dernierPas = now;
    if (vise == null) return null;
    if (_cap == null) return _cap = vise;
    final delta = ((vise - _cap! + 540) % 360) - 180;
    final k = 1 - math.exp(-dt / _secondes(reponseFleche));
    _cap = (_cap! + delta * k + 360) % 360;
    return _cap;
  }

  /// Plus rien ne bouge : la carte peut cesser de redessiner.
  bool settledAt(DateTime now) {
    final positionArrivee = _debut == null || now.difference(_debut!) >= _duree;
    final vise = _capVise;
    final capArrive =
        vise == null ||
        _cap == null ||
        (((vise - _cap! + 540) % 360) - 180).abs() < 0.5;
    return positionArrivee && capArrive;
  }

  static double _secondes(Duration d) => d.inMicroseconds / 1e6;
}

/// **Au plus un envoi par [pas]**, mesuré à l'HEURE RÉELLE.
///
/// 🔴 **Pourquoi l'heure réelle — corrigé le 2026-09-26** (Jay : *« parfois
/// l'indicateur de direction se fige et il faut relancer la carte »*). La
/// carte comparait le temps écoulé de son horloge d'animation au dernier
/// envoi. Or cette horloge s'endort quand rien ne bouge et **repart de zéro**
/// à chaque réveil, alors que le dernier envoi gardait l'ancienne mesure :
/// après deux minutes d'animation, plus rien ne partait pendant deux minutes
/// au réveil. Point et flèche figés, sans erreur ; relancer la carte
/// remettait les deux à zéro. Protégé par `test/my_point_motion_test.dart`.
class FrameGate {
  FrameGate(this.pas);

  final Duration pas;
  DateTime? _dernier;

  /// Laisse-t-on passer un envoi à [now] ? Si oui, il est compté.
  bool laisse(DateTime now) {
    final d = _dernier;
    // Une heure qui recule (réglage du téléphone) ne bloque jamais.
    if (d != null && !now.isBefore(d) && now.difference(d) < pas) {
      return false;
    }
    _dernier = now;
    return true;
  }
}
