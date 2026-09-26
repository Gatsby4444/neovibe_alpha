import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// **Les repères de la carte, dessinés en images** — la carte n'affiche que
/// des images. Une seule pièce pour mon point et, demain, ceux de mes amis :
/// le même rond, la même photo, le même contour.
///
/// Jay, 2026-09-26 : *« le rond de position est la photo de profil de
/// l'utilisateur, et les ronds de ses amis sont leur photo de profil »*.
abstract final class MapMarkers {
  /// Lit une photo de profil (le fichier du cache d'avatars). Nulle si
  /// absente ou illisible : le repère retombe alors sur les initiales.
  static Future<ui.Image?> photo(File? fichier, {int taillePx = 160}) async {
    if (fichier == null) return null;
    try {
      final codec = await ui.instantiateImageCodec(
        await fichier.readAsBytes(),
        targetWidth: taillePx,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// **Un rond de profil** : la photo (ou les initiales), un anneau de
  /// couleur, un liseré de la couleur du fond pour rester lisible sur une
  /// carte claire comme sombre — et, si [cone], le cône de direction vers
  /// le HAUT de l'image (la carte le tourne selon la boussole).
  ///
  /// [cote] et [rayon] sont en points ; l'image est rendue à la densité de
  /// l'écran ([dpr]).
  static Future<Uint8List> rond({
    required double dpr,
    required double cote,
    required double rayon,
    required Color anneau,
    required Color fond,
    ui.Image? photo,
    String initiales = '',
    bool cone = false,
    Color? couleurCone,
  }) async {
    final c = cote * dpr / 2;
    final centre = Offset(c, c);
    final r = rayon * dpr;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    if (cone) {
      // 70° d'ouverture, qui s'efface en s'éloignant du rond.
      final teinte = couleurCone ?? anneau;
      final arc = Path()
        ..moveTo(centre.dx, centre.dy)
        ..arcTo(
          Rect.fromCircle(center: centre, radius: c),
          -math.pi / 2 - 35 * math.pi / 180,
          70 * math.pi / 180,
          false,
        )
        ..close();
      canvas.drawPath(
        arc,
        Paint()
          ..shader = ui.Gradient.radial(centre, c, [
            teinte.withValues(alpha: 0.55),
            teinte.withValues(alpha: 0),
          ]),
      );
    }

    // Ombre, liseré de fond, anneau de couleur.
    canvas.drawCircle(
      centre,
      r + 2.5 * dpr,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * dpr),
    );
    canvas.drawCircle(centre, r + 2 * dpr, Paint()..color = fond);
    canvas.drawCircle(centre, r + 0.5 * dpr, Paint()..color = anneau);

    // La photo, découpée en rond — ou les initiales sur l'anneau.
    final interieur = Rect.fromCircle(center: centre, radius: r - 1.5 * dpr);
    if (photo != null) {
      canvas.save();
      canvas.clipPath(Path()..addOval(interieur));
      final w = photo.width.toDouble();
      final h = photo.height.toDouble();
      final s = math.min(w, h);
      canvas.drawImageRect(
        photo,
        Rect.fromLTWH((w - s) / 2, (h - s) / 2, s, s),
        interieur,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    } else {
      canvas.drawOval(interieur, Paint()..color = fond);
      final texte = TextPainter(
        text: TextSpan(
          text: initiales,
          style: TextStyle(
            color: anneau,
            fontSize: r * 0.8,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      texte.paint(canvas, centre - Offset(texte.width / 2, texte.height / 2));
    }

    final image = await recorder.endRecording().toImage(
      (cote * dpr).round(),
      (cote * dpr).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// **Le cône de direction seul** — posé À PLAT sur la carte (il tourne
  /// avec la boussole et s'incline avec elle), sous le rond de profil, qui,
  /// lui, reste face à l'écran : une photo posée à plat serait écrasée dès
  /// que la carte s'incline.
  static Future<Uint8List> cone({
    required double dpr,
    required double cote,
    required Color couleur,
  }) async {
    final c = cote * dpr / 2;
    final centre = Offset(c, c);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final arc = Path()
      ..moveTo(centre.dx, centre.dy)
      ..arcTo(
        Rect.fromCircle(center: centre, radius: c),
        -math.pi / 2 - 35 * math.pi / 180,
        70 * math.pi / 180,
        false,
      )
      ..close();
    canvas.drawPath(
      arc,
      Paint()
        ..shader = ui.Gradient.radial(centre, c, [
          couleur.withValues(alpha: 0.6),
          couleur.withValues(alpha: 0),
        ]),
    );
    final image = await recorder.endRecording().toImage(
      (cote * dpr).round(),
      (cote * dpr).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// Une image transparente d'un pixel : le cône « éteint » quand la
  /// boussole ne répond pas.
  static Future<Uint8List> vide() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder);
    final image = await recorder.endRecording().toImage(1, 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// Les initiales d'un nom (« Jay B » → « JB »), pour un profil sans photo.
  static String initiales(String nom) {
    final mots = nom.trim().split(RegExp(r'\s+')).where((m) => m.isNotEmpty);
    return mots.take(2).map((m) => m.characters.first.toUpperCase()).join();
  }
}
