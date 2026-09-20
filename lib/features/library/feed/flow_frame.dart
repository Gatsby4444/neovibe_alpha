import 'dart:math' as math;
import 'dart:ui';

/// **Le cadre d'un Flow en plein écran** — le rectangle que la vidéo occupe
/// vraiment sur la page, et ce qui se pose DEDANS.
///
/// Un Flow est publié à SON format et s'affiche en `BoxFit.contain` : un Flow
/// carré laisse deux bandes noires, en haut et en bas. Ce qui l'habille —
/// l'auteur en haut, la légende en bas — doit se poser **sur la vidéo**, pas
/// sur l'écran (Jay, 2026-09-20 : *« rappelle-toi, il doit être dans le
/// contenu en plein écran »*). Ces mesures sont pures pour être testées
/// (`test/flow_frame_test.dart`) : un décalage ne lève aucune erreur.
abstract final class FlowFrame {
  /// Où la vidéo se pose sur une page de [page], à [ratio] (largeur /
  /// hauteur) : contenue, centrée.
  static Rect rectFor({required double ratio, required Size page}) {
    if (page.isEmpty || ratio <= 0 || !ratio.isFinite) {
      return Offset.zero & page;
    }
    final byWidth = Size(page.width, page.width / ratio);
    final fitted = byWidth.height <= page.height
        ? byWidth
        : Size(page.height * ratio, page.height);
    return Rect.fromCenter(
      center: page.center(Offset.zero),
      width: fitted.width,
      height: fitted.height,
    );
  }

  /// Ce que le bord haut de la vidéo doit rendre à l'encoche : la part de
  /// [safeTop] que la vidéo recouvre. Zéro si la vidéo commence dessous.
  static double topInset({required Rect rect, required double safeTop}) =>
      math.max(0, safeTop - rect.top);

  /// Idem pour la barre du bas.
  static double bottomInset({
    required Rect rect,
    required Size page,
    required double safeBottom,
  }) => math.max(0, safeBottom - (page.height - rect.bottom));

  /// La place à laisser au bouton Fermer (en haut à droite de l'écran,
  /// [closeWidth] de large et de haut, sous l'encoche) quand l'auteur, posé
  /// au haut de la vidéo, arrive à sa hauteur. Zéro sinon.
  static double closeReserve({
    required Rect rect,
    required Size page,
    required double safeTop,
    double closeWidth = 56,
  }) {
    final authorTop = math.max(rect.top, safeTop);
    if (authorTop >= safeTop + closeWidth) return 0;
    return math.max(0, closeWidth - (page.width - rect.right));
  }

  /// Où centrer le cœur : **au milieu de l'écran** (Jay, 2026-09-20), en
  /// coordonnées de la page. La page occupe le bas de l'écran (un bandeau
  /// peut la raccourcir par le haut), donc le milieu de l'écran est à
  /// `page.height - screenHeight / 2` depuis le haut de la page.
  static double heartCenter({
    required Size page,
    required double screenHeight,
  }) => page.height - screenHeight / 2;
}
