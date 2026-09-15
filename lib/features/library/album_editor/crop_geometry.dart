import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'album_draft.dart';

/// **La géométrie du cadrage, une seule fois** — pour l'aperçu, l'export
/// photo et le transcodeur vidéo.
///
/// Le cadre est fixe (le ratio de l'album). Sous lui, l'image peut être
/// **tournée** (quarts de tour + redressement fin) et **déplacée / zoomée**.
/// Pour qu'aucun coin vide n'apparaisse jamais, le cadrage se choisit dans le
/// **plus grand rectangle droit inscrit dans l'image tournée** : tourner
/// resserre automatiquement la vue, comme sur Instagram.
///
/// Tout est exprimé dans le repère **F** : centré sur le centre de l'image
/// affichée, axes de l'écran, unités = pixels de la source affichée (après
/// rotation EXIF). Un point `p` de F correspond au pixel source
/// `centre + R(−θ)·p`, où θ est la rotation de l'image.
///
/// Ce que les moteurs consomment :
/// - [corners] : les 4 coins du cadre en coordonnées source normalisées —
///   l'aperçu et l'export photo (shader Flutter) comme la vidéo (shader GL)
///   échantillonnent par interpolation affine de ces coins ;
/// - [matrix] : la même transformation en matrice, pour dessiner une image
///   entière sous le cadre (aperçu vidéo, où le shader n'a pas la main).
abstract final class CropGeometry {
  /// Le plus grand rectangle aux axes de l'écran inscrit dans un rectangle
  /// [w]×[h] tourné de [radians]. Centré, comme l'image.
  static (double, double) inscribed(double w, double h, double radians) {
    if (w <= 0 || h <= 0) return (0, 0);
    final sinA = math.sin(radians).abs();
    final cosA = math.cos(radians).abs();
    final widthIsLonger = w >= h;
    final sideLong = widthIsLonger ? w : h;
    final sideShort = widthIsLonger ? h : w;
    if (sideShort <= 2 * sinA * cosA * sideLong ||
        (sinA - cosA).abs() < 1e-10) {
      // Le rectangle inscrit touche deux bords opposés par un seul point :
      // demi-carré limité par le petit côté.
      final x = sideShort / 2;
      return widthIsLonger ? (x / sinA, x / cosA) : (x / cosA, x / sinA);
    }
    final cos2a = cosA * cosA - sinA * sinA;
    return ((w * cosA - h * sinA) / cos2a, (h * cosA - w * sinA) / cos2a);
  }

  /// Le rectangle du cadre dans F, pour un média et un ratio.
  static Rect frameRect(AlbumDraftMedia m, double aspect) {
    final theta = m.crop.radians;
    final (wr, hr) = inscribed(
      m.srcWidth.toDouble(),
      m.srcHeight.toDouble(),
      theta,
    );
    final r = m.crop.rectWithin(wr, hr, aspect);
    return Rect.fromLTWH(-wr / 2 + r.left, -hr / 2 + r.top, r.width, r.height);
  }

  /// Un point de F → le pixel source correspondant.
  static Offset toSource(Offset p, AlbumDraftMedia m) {
    final t = -m.crop.radians;
    final c = math.cos(t);
    final s = math.sin(t);
    return Offset(
      m.srcWidth / 2 + c * p.dx - s * p.dy,
      m.srcHeight / 2 + s * p.dx + c * p.dy,
    );
  }

  /// Les quatre coins du cadre — **haut-gauche, haut-droit, bas-gauche,
  /// bas-droit** — en coordonnées source normalisées (0..1 de l'image
  /// affichée). Toujours dans l'image : le cadre vit dans le rectangle inscrit.
  static List<Offset> corners(AlbumDraftMedia m, double aspect) {
    final f = frameRect(m, aspect);
    Offset n(Offset p) {
      final s = toSource(p, m);
      return Offset(s.dx / m.srcWidth, s.dy / m.srcHeight);
    }

    return [n(f.topLeft), n(f.topRight), n(f.bottomLeft), n(f.bottomRight)];
  }

  /// La transformation qui pose l'image entière (dessinée en (0,0),
  /// `srcWidth`×`srcHeight`) sous un cadre de [frameW]×[frameH] pixels
  /// d'écran, pour ce cadrage : translation, échelle, rotation.
  static Matrix4 matrix(
    AlbumDraftMedia m,
    double aspect, {
    required double frameW,
    required double frameH,
  }) {
    final f = frameRect(m, aspect);
    final scale = frameW / f.width;
    return Matrix4.identity()
      ..translateByDouble(frameW / 2, frameH / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-f.center.dx, -f.center.dy, 0, 1)
      ..rotateZ(m.crop.radians)
      ..translateByDouble(-m.srcWidth / 2, -m.srcHeight / 2, 0, 1);
  }

  /// Un déplacement du doigt de ([dx], [dy]) pixels d'écran sur un cadre de
  /// [frameW] de large : le nouveau cadrage. Le cadre montre `frameRect`
  /// étiré sur `frameW`, un pixel d'écran vaut donc `f.width / frameW` unités
  /// de F.
  static CropSpec panned(
    AlbumDraftMedia m,
    double aspect,
    double dx,
    double dy, {
    required double frameW,
  }) {
    final theta = m.crop.radians;
    final (wr, hr) = inscribed(
      m.srcWidth.toDouble(),
      m.srcHeight.toDouble(),
      theta,
    );
    final f = frameRect(m, aspect);
    final unit = f.width / frameW;
    return m.crop
        .copyWith(
          cx: m.crop.cx - dx * unit / wr,
          cy: m.crop.cy - dy * unit / hr,
        )
        .clampedWithin(wr, hr, aspect);
  }

  /// Le zoom « adapter » de ce média : l'image entière dans le cadre.
  static double fitZoom(AlbumDraftMedia m, double aspect) {
    final (wr, hr) = inscribed(
      m.srcWidth.toDouble(),
      m.srcHeight.toDouble(),
      m.crop.radians,
    );
    return CropSpec.fitZoom(wr, hr, aspect);
  }

  /// L'image est-elle vue entière (« adaptée ») ?
  static bool isFitted(AlbumDraftMedia m, double aspect) =>
      m.crop.zoom <= fitZoom(m, aspect) + 1e-6;

  /// Adapter ↔ Remplir : l'image entière avec des bandes, ou le cadre plein.
  static CropSpec toggleFit(AlbumDraftMedia m, double aspect) {
    final (wr, hr) = inscribed(
      m.srcWidth.toDouble(),
      m.srcHeight.toDouble(),
      m.crop.radians,
    );
    final fit = CropSpec.fitZoom(wr, hr, aspect);
    final target = isFitted(m, aspect) ? 1.0 : fit;
    return m.crop
        .copyWith(zoom: target, cx: 0.5, cy: 0.5)
        .clampedWithin(wr, hr, aspect);
  }

  static CropSpec zoomed(AlbumDraftMedia m, double aspect, double factor) {
    final (wr, hr) = inscribed(
      m.srcWidth.toDouble(),
      m.srcHeight.toDouble(),
      m.crop.radians,
    );
    final min = CropSpec.fitZoom(wr, hr, aspect);
    return m.crop
        .copyWith(zoom: (m.crop.zoom * factor).clamp(min, CropSpec.maxZoom))
        .clampedWithin(wr, hr, aspect);
  }
}
