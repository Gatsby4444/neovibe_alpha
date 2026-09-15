import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/models/library_item.dart';
import '../../cards/native_media.dart';
import '../library_repository.dart';
import 'album_draft.dart';
import 'crop_geometry.dart';
import 'editor_images.dart';
import 'grade_shader.dart';
import 'overlay_model.dart';
import 'overlay_painter.dart';

/// Rend un média du brouillon en **fichier prêt à publier**.
///
/// - Une **photo** est dessinée par Flutter avec **le shader de l'aperçu**
///   (`GradeShader` : cadrage, rotation, filtre, réglages, vignette) puis les
///   calques par **le peintre de l'aperçu** (`OverlayPainter`), et encodée en
///   JPEG par le natif (`dart:ui` ne sait écrire que du PNG). Ce que l'aperçu
///   affiche est ce qui sort, par construction.
/// - Une **vidéo** passe par le transcodeur natif, qui reçoit les mêmes coins
///   de cadrage, les mêmes nombres de couleur (`ColorGrade.toUniforms`) et le
///   calque des textes et autocollants rendu en PNG à la taille de sortie ;
///   sa couverture est tirée du fichier **produit** (donc déjà cadrée,
///   corrigée, avec ses calques).
abstract final class AlbumExport {
  /// La taille de sortie pour un ratio : **1080 de large**, comme Instagram
  /// (1080×1440 en 3:4). Paire, pour l'encodeur vidéo. Seule définition — le
  /// natif reçoit ces deux nombres.
  static (int, int) outputSize(AlbumAspect aspect) {
    const w = 1080;
    final h = (w / aspect.ratio).round() & ~1;
    return (w, h);
  }

  /// Exporte [m] dans [dir]. Photo : un rendu Flutter puis un appel natif.
  /// Vidéo : le transcodeur natif, avec sa progression (0..1).
  static Future<AlbumMediaUpload> render(
    AlbumDraftMedia m,
    AlbumAspect aspect,
    Directory dir, {
    void Function(double progress)? onProgress,
  }) => m.isVideo
      ? _renderVideo(m, aspect, dir, onProgress: onProgress)
      : _renderPhoto(m, aspect, dir);

  /// Les images des autocollants d'un média, décodées pour l'export.
  static Future<Map<String, ui.Image>> _stickerImages(AlbumDraftMedia m) async {
    final out = <String, ui.Image>{};
    for (final o in m.overlays) {
      if (o is StickerOverlay && !o.isEmoji && !out.containsKey(o.imagePath)) {
        out[o.imagePath!] = await EditorImages.decodeBounded(
          File(o.imagePath!),
          1024,
        );
      }
    }
    return out;
  }

  static Future<AlbumMediaUpload> _renderPhoto(
    AlbumDraftMedia m,
    AlbumAspect aspect,
    Directory dir,
  ) async {
    await GradeShader.load();
    final (outW, outH) = outputSize(aspect);
    // La source, bornée : le cadre sort à 1080 px de large, la source n'a
    // pas besoin d'être décodée plus grand que ce que le zoom demande.
    final side = math.min(
      math.max(m.srcWidth, m.srcHeight),
      (1080 * CropSpec.maxZoom * 1.5).round(),
    );
    final image = await EditorImages.decodeBounded(m.source, side);
    final stickers = await _stickerImages(m);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final dst = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
      // Le décodeur applique-t-il la rotation EXIF ? La sonde a rendu les
      // dimensions APRÈS rotation. Si l'image décodée est dans l'autre sens,
      // on la présente au shader comme une source « couchée » : les coins
      // sont calculés pour l'image affichée, puis ramenés à l'image stockée
      // — la même chose que fait le transcodeur pour une vidéo.
      final decodedUpright =
          (image.width >= image.height) == (m.srcWidth >= m.srcHeight) ||
          m.srcWidth == m.srcHeight;
      final media = decodedUpright ? m : _unrotated(m);
      GradeShader.paint(canvas, dst, image, media, aspect.ratio);
      OverlayPainter(
        images: (path) => stickers[path],
      ).paintAll(canvas, Size(outW.toDouble(), outH.toDouble()), m.overlays);
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
      for (final s in stickers.values) {
        s.dispose();
      }
    }
  }

  /// Le média vu comme sa source STOCKÉE (non redressée) : dimensions
  /// échangées et la rotation du fichier ajoutée aux quarts de tour, pour que
  /// les coins tombent au bon endroit d'une image que le décodeur n'a pas
  /// tournée.
  static AlbumDraftMedia _unrotated(AlbumDraftMedia m) => AlbumDraftMedia(
    id: m.id,
    source: m.source,
    isVideo: m.isVideo,
    srcWidth: m.srcHeight,
    srcHeight: m.srcWidth,
    rotation: 0,
    durationMs: m.durationMs,
    crop: m.crop.copyWith(turns: (m.crop.turns + m.rotation ~/ 90) % 4),
    filter: m.filter,
    filterStrength: m.filterStrength,
    adjust: m.adjust,
    overlays: m.overlays,
    trim: m.trim,
  );

  static Future<AlbumMediaUpload> _renderVideo(
    AlbumDraftMedia m,
    AlbumAspect aspect,
    Directory dir, {
    void Function(double progress)? onProgress,
  }) async {
    final (outW, outH) = outputSize(aspect);
    final corners = CropGeometry.corners(m, aspect.ratio);
    final trim = m.effectiveTrim;
    final file = File('${dir.path}/album_${m.id}.mp4');

    // Le calque des textes et autocollants, rendu une fois à la taille de
    // sortie : le transcodeur le pose sur chaque image.
    String? overlayPath;
    if (m.overlays.isNotEmpty) {
      final stickers = await _stickerImages(m);
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        OverlayPainter(
          images: (path) => stickers[path],
        ).paintAll(canvas, Size(outW.toDouble(), outH.toDouble()), m.overlays);
        final picture = recorder.endRecording();
        final img = await picture.toImage(outW, outH);
        picture.dispose();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final f = File('${dir.path}/album_${m.id}_overlay.png');
        await f.writeAsBytes(png!.buffer.asUint8List());
        overlayPath = f.path;
      } finally {
        for (final s in stickers.values) {
          s.dispose();
        }
      }
    }

    final result = await NativeMedia.transcode(
      source: m.source.path,
      dest: file.path,
      startMs: trim.startMs,
      endMs: trim.endMs,
      corners: [
        for (final c in corners) ...[c.dx, c.dy],
      ],
      outWidth: outW,
      outHeight: outH,
      uniforms: m.grade.toUniforms(),
      rotation: m.rotation,
      overlayPath: overlayPath,
      onProgress: onProgress,
    );
    // La couverture, tirée du fichier PRODUIT : déjà cadrée, corrigée, avec
    // ses calques.
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
