import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'album_draft.dart';
import 'color_grade.dart';
import 'crop_geometry.dart';

/// **Le shader de l'éditeur, côté Dart** : charge `shaders/album_grade.frag`
/// une fois, et dessine une image source à travers un cadrage
/// (`CropGeometry.corners`) et un réglage (`ColorGrade.toUniforms`).
///
/// C'est le **même dessin** pour l'aperçu à l'écran (`GradePainter`) et pour
/// l'export photo (`paint` sur le canvas d'un `PictureRecorder`) : ce qu'on
/// voit est ce qui sort, par construction.
abstract final class GradeShader {
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;

  /// Charge le programme (une fois). À appeler tôt — l'écran d'édition
  /// l'attend à son ouverture.
  static Future<ui.FragmentProgram> load() =>
      _loading ??= ui.FragmentProgram.fromAsset(
        'shaders/album_grade.frag',
      ).then((p) => _program = p);

  /// Le programme s'il est chargé, sinon nul (l'aperçu montre alors la photo
  /// brute le temps du chargement — une fraction de seconde).
  static ui.FragmentProgram? get program => _program;

  /// Dessine [image] (la source, entière) dans [rect], à travers le cadrage
  /// de [m] au ratio [aspect] et ses réglages. Le résultat remplit [rect].
  static void paint(
    ui.Canvas canvas,
    Rect rect,
    ui.Image image,
    AlbumDraftMedia m,
    double aspect,
  ) {
    final program = _program;
    if (program == null) return;
    final shader = program.fragmentShader();
    final corners = CropGeometry.corners(m, aspect);
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    // 0-1 taille, 2-3 origine
    f(rect.width);
    f(rect.height);
    f(rect.left);
    f(rect.top);
    // 4-9 les trois coins (haut-gauche, haut-droit, bas-gauche)
    for (final c in corners.take(3)) {
      f(c.dx);
      f(c.dy);
    }
    // 10-33 le contrat des couleurs (24 nombres)
    for (final v in m.grade.toUniforms()) {
      f(v);
    }
    // 34-35 un texel de la source
    f(1 / image.width);
    f(1 / image.height);
    shader.setImageSampler(0, image);
    canvas.drawRect(rect, Paint()..shader = shader);
  }
}

/// L'aperçu d'une photo à travers le shader, dans le cadre.
class GradePainter extends CustomPainter {
  const GradePainter({
    required this.image,
    required this.media,
    required this.aspect,
  });

  final ui.Image image;
  final AlbumDraftMedia media;
  final double aspect;

  @override
  void paint(Canvas canvas, Size size) {
    GradeShader.paint(canvas, Offset.zero & size, image, media, aspect);
  }

  @override
  bool shouldRepaint(GradePainter old) =>
      old.image != image ||
      old.media.crop != media.crop ||
      old.media.grade != media.grade ||
      old.aspect != aspect;
}

/// Une vignette de photo à travers un réglage donné (les puces des filtres) :
/// le cadrage du média, et un [ColorGrade] imposé.
class GradedThumbPainter extends CustomPainter {
  const GradedThumbPainter({
    required this.image,
    required this.media,
    required this.aspect,
    required this.grade,
  });

  final ui.Image image;
  final AlbumDraftMedia media;
  final double aspect;
  final ColorGrade grade;

  @override
  void paint(Canvas canvas, Size size) {
    GradeShader.paint(
      canvas,
      Offset.zero & size,
      image,
      // Le cadrage du média, mais CE réglage.
      media.copyWith(
        filter: AlbumFilter.normal,
        filterStrength: 1,
        adjust: grade,
      ),
      aspect,
    );
  }

  @override
  bool shouldRepaint(GradedThumbPainter old) =>
      old.image != image ||
      old.media.crop != media.crop ||
      old.grade != grade ||
      old.aspect != aspect;
}
