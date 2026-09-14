import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/models/library_item.dart';
import '../../cards/native_media.dart';
import '../library_repository.dart';
import 'album_draft.dart';
import 'color_grade.dart';

/// Rend un média du brouillon en **fichier prêt à publier**.
///
/// - Une **photo** est dessinée par Flutter (`Canvas` : recadrage, matrice de
///   couleurs, vignette) puis encodée en JPEG par le natif (`dart:ui` ne sait
///   écrire que du PNG). Ce que l'aperçu affiche (`ColorFiltered` + le même
///   voile) est ce qui sort.
/// - Une **vidéo** passe par le transcodeur natif, avec la même matrice et la
///   même vignette dans son shader ; sa couverture est tirée du fichier
///   **produit** (donc déjà recadrée et corrigée).
abstract final class AlbumExport {
  /// La taille de sortie pour un ratio : **1080 de large**, comme Instagram
  /// (1080×1350 en 4:5, 1080×1080, 1080×566 en 1.91:1). Paire, pour
  /// l'encodeur vidéo. Seule définition — le natif reçoit ces deux nombres.
  static (int, int) outputSize(AlbumAspect aspect) {
    const w = 1080;
    final h = (w / aspect.ratio).round() & ~1;
    return (w, h);
  }

  /// Le voile de vignette, à dessiner PAR-DESSUS l'image dans [rect] : le
  /// même pour l'aperçu et pour l'export — huit arrêts qui suivent
  /// `Vignette.alphaAt`, pas un dégradé linéaire approximatif.
  static Paint? vignettePaint(Rect rect, double v) {
    if (v <= 0) return null;
    const n = 8;
    final stops = <double>[0, Vignette.start];
    final colors = <Color>[const Color(0x00000000), const Color(0x00000000)];
    for (var i = 1; i <= n; i++) {
      final d = Vignette.start + (1 - Vignette.start) * i / n;
      stops.add(d);
      colors.add(Color.fromRGBO(0, 0, 0, Vignette.alphaAt(d, v)));
    }
    // Rayon = la demi-diagonale : la distance 1 est le coin.
    final radius =
        math.sqrt(rect.width * rect.width + rect.height * rect.height) / 2;
    return Paint()
      ..shader = ui.Gradient.radial(rect.center, radius, colors, stops);
  }

  /// Exporte [m] dans [dir]. Photo : synchrone côté Dart puis un appel natif.
  /// Vidéo : le transcodeur natif, avec sa progression (0..1).
  static Future<AlbumMediaUpload> render(
    AlbumDraftMedia m,
    AlbumAspect aspect,
    Directory dir, {
    void Function(double progress)? onProgress,
  }) => m.isVideo
      ? _renderVideo(m, aspect, dir, onProgress: onProgress)
      : _renderPhoto(m, aspect, dir);

  static Future<AlbumMediaUpload> _renderPhoto(
    AlbumDraftMedia m,
    AlbumAspect aspect,
    Directory dir,
  ) async {
    final (outW, outH) = outputSize(aspect);
    final crop = m.crop.sourceRect(m.srcWidth, m.srcHeight, aspect.ratio);

    // Décoder juste assez grand : le cadre doit sortir à `outW` pixels, pas
    // plus. Une photo 4000×3000 zoomée ×3 se décode donc à ~3240 px de large,
    // une photo non zoomée à ~1080 — au lieu de 48 Mo de pixels à chaque fois.
    final targetW = math.min(
      m.srcWidth,
      (outW * m.srcWidth / crop.width).ceil(),
    );
    final bytes = await m.source.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: targetW);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    codec.dispose();
    try {
      // Le décodeur applique-t-il la rotation EXIF ? La sonde a rendu les
      // dimensions APRÈS rotation ; si l'image décodée est dans l'autre sens,
      // il ne l'a pas fait, et on tourne nous-mêmes au dessin.
      final decodedUpright =
          (image.width >= image.height) == (m.srcWidth >= m.srcHeight);
      final rotate = !decodedUpright && m.rotation != 0;
      final scale = rotate
          ? image.height / m.srcWidth
          : image.width / m.srcWidth;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final dst = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
      canvas.clipRect(dst);
      final paint = Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = ColorFilter.matrix(m.grade.toMatrix());

      // Le cadre, en pixels de l'image décodée (repère AFFICHÉ).
      final src = Rect.fromLTWH(
        crop.left * scale,
        crop.top * scale,
        crop.width * scale,
        crop.height * scale,
      );
      if (rotate) {
        // Dessiner l'image entière redressée, et n'en garder que le cadre.
        // De droite à gauche : (1) redresser l'image stockée dans le repère
        // affiché, (2) placer `src` à l'origine, (3) l'étirer sur `dst`.
        canvas.save();
        canvas.scale(dst.width / src.width, dst.height / src.height);
        canvas.translate(-src.left, -src.top);
        final upW = m.rotation % 180 == 0
            ? image.width.toDouble()
            : image.height.toDouble();
        final upH = m.rotation % 180 == 0
            ? image.height.toDouble()
            : image.width.toDouble();
        switch (m.rotation) {
          case 90:
            canvas.translate(upW, 0);
          case 180:
            canvas.translate(upW, upH);
          case 270:
            canvas.translate(0, upH);
        }
        canvas.rotate(m.rotation * math.pi / 180);
        canvas.drawImage(image, Offset.zero, paint);
        canvas.restore();
      } else {
        canvas.drawImageRect(image, src, dst, paint);
      }
      final veil = vignettePaint(dst, m.grade.vignette);
      if (veil != null) canvas.drawRect(dst, veil);

      final picture = recorder.endRecording();
      final out = await picture.toImage(outW, outH);
      picture.dispose();
      final rgba = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      out.dispose();
      final file = File('${dir.path}/album_${m.id}.jpg');
      await NativeMedia.encodeJpeg(
        rgba: rgba!.buffer.asUint8List(),
        width: outW,
        height: outH,
        dest: file.path,
      );
      return AlbumMediaUpload(file, isVideo: false, width: outW, height: outH);
    } finally {
      image.dispose();
    }
  }

  static Future<AlbumMediaUpload> _renderVideo(
    AlbumDraftMedia m,
    AlbumAspect aspect,
    Directory dir, {
    void Function(double progress)? onProgress,
  }) async {
    final (outW, outH) = outputSize(aspect);
    final crop = m.crop.normalizedRect(m.srcWidth, m.srcHeight, aspect.ratio);
    final trim = m.effectiveTrim;
    final file = File('${dir.path}/album_${m.id}.mp4');
    final result = await NativeMedia.transcode(
      source: m.source.path,
      dest: file.path,
      startMs: trim.startMs,
      endMs: trim.endMs,
      cropLeft: crop.left,
      cropTop: crop.top,
      cropWidth: crop.width,
      cropHeight: crop.height,
      outWidth: outW,
      outHeight: outH,
      colorMatrix: m.grade.toMatrix(),
      vignette: m.grade.vignette,
      onProgress: onProgress,
    );
    // La couverture, tirée du fichier PRODUIT : déjà recadrée et corrigée.
    final poster = File('${dir.path}/album_${m.id}_poster.jpg');
    final ok = await NativeMedia.videoThumbnail(
      source: file.path,
      dest: poster.path,
      width: outW,
      atMs: (trim.coverMs - trim.startMs).clamp(0, result.durationMs),
    );
    if (!ok) throw StateError('couverture impossible à extraire');
    return AlbumMediaUpload(
      file,
      isVideo: true,
      durationMs: math.min(result.durationMs, kAlbumMaxVideoMs),
      poster: poster,
      width: outW,
      height: outH,
    );
  }
}
