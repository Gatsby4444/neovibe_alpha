import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/diagnostics/app_log.dart';
import '../native_media.dart';
import 'media_edit.dart';
import 'crop_geometry.dart';
import 'editor_images.dart';
import 'grade_shader.dart';
import 'overlay_model.dart';
import 'overlay_painter.dart';

/// Rend une face éditée en **fichier prêt à l'envoi**.
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
abstract final class MediaExport {
  /// La taille de sortie : **1080 de large** (1080×1920 en 9:16). Paire,
  /// pour l'encodeur vidéo. Seule définition — le natif reçoit ces deux
  /// nombres.
  static (int, int) outputSize(MediaAspect aspect) {
    const w = 1080;
    final h = (w / aspect.ratio).round() & ~1;
    return (w, h);
  }

  /// Exporte [m] dans [dir], **ici et maintenant** — une face à la fois, sous
  /// les yeux de l'utilisateur, à « Suivant ». Photo : un rendu Flutter puis
  /// un appel natif. Vidéo : le transcodeur natif, avec sa progression (0..1).
  ///
  /// ⚠️ Le fichier rendu est **final** : la file native de publication
  /// (`docs/file-de-publication.md`) le scelle et l'envoie tel quel, sans le
  /// retranscoder. Les faces sont rendues ici, et pas dans la file, parce
  /// qu'un même rendu sert toutes les destinations d'un envoi (story, chat,
  /// bibliothèque).
  static Future<RenderedMedia> render(
    MediaEdit m,
    MediaAspect aspect,
    Directory dir, {
    void Function(double progress)? onProgress,
    int maxVideoMs = kMaxFaceVideoMs,
  }) => m.isVideo
      ? _renderVideo(
          m,
          aspect,
          dir,
          onProgress: onProgress,
          maxVideoMs: maxVideoMs,
        )
      : _renderPhotoMedia(m, aspect, dir);

  static Future<RenderedMedia> _renderPhotoMedia(
    MediaEdit m,
    MediaAspect aspect,
    Directory dir,
  ) async {
    final (outW, outH) = outputSize(aspect);
    final file = await renderPhoto(m, aspect, dir);
    return RenderedMedia(file, isVideo: false, width: outW, height: outH);
  }

  /// Les images des autocollants d'un média, décodées pour l'export.
  static Future<Map<String, ui.Image>> _stickerImages(MediaEdit m) async {
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

  /// Rend une photo : le fichier JPEG produit, à [outputSize].
  static Future<File> renderPhoto(
    MediaEdit m,
    MediaAspect aspect,
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
      return file;
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
  static MediaEdit _unrotated(MediaEdit m) => MediaEdit(
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

  /// Le calque des textes et autocollants d'une vidéo, rendu une fois à la
  /// taille de sortie en PNG : le transcodeur le pose sur chaque image. Nul
  /// s'il n'y a rien à poser.
  static Future<String?> renderOverlay(
    MediaEdit m,
    MediaAspect aspect,
    Directory dir,
  ) async {
    if (m.overlays.isEmpty) return null;
    final (outW, outH) = outputSize(aspect);
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
      return f.path;
    } finally {
      for (final s in stickers.values) {
        s.dispose();
      }
    }
  }

  /// **Les paramètres du transcodeur** pour [m] — la seule définition : les
  /// coins du cadrage, le rognage, les nombres de couleur, la rotation, le
  /// calque. Les clés sont celles que le Kotlin lit (`TranscodeSpec`).
  static Map<String, Object?> videoSpec(
    MediaEdit m,
    MediaAspect aspect, {
    required String? overlayPath,
  }) {
    final (outW, outH) = outputSize(aspect);
    final corners = CropGeometry.corners(m, aspect.ratio);
    final trim = m.effectiveTrim;
    return {
      'startMs': trim.startMs,
      'endMs': trim.endMs,
      'corners': [
        for (final c in corners) ...[c.dx, c.dy],
      ],
      'outWidth': outW,
      'outHeight': outH,
      'uniforms': m.grade.toUniforms(),
      'overlayPath': overlayPath,
      'rotation': m.rotation,
    };
  }

  static Future<RenderedMedia> _renderVideo(
    MediaEdit m,
    MediaAspect aspect,
    Directory dir, {
    void Function(double progress)? onProgress,
    int maxVideoMs = kMaxFaceVideoMs,
  }) async {
    final (outW, outH) = outputSize(aspect);
    final trim = m.effectiveTrim;
    final file = File('${dir.path}/album_${m.id}.mp4');
    final overlayPath = await renderOverlay(m, aspect, dir);
    final spec = videoSpec(m, aspect, overlayPath: overlayPath);

    final result = await NativeMedia.transcode(
      source: m.source.path,
      dest: file.path,
      startMs: spec['startMs']! as int,
      endMs: spec['endMs']! as int,
      corners: spec['corners']! as List<double>,
      outWidth: outW,
      outHeight: outH,
      uniforms: spec['uniforms']! as List<double>,
      rotation: m.rotation,
      overlayPath: overlayPath,
      onProgress: onProgress,
    );
    // Ce que le transcodeur a fait, dans le journal : c'est là qu'on lira
    // le décodeur employé et la luminance relue quand une vidéo sort mal.
    AppLog.instance.app(
      'Vidéo transcodée — ${m.id.substring(0, 8)} · ${result.durationMs} ms',
      result.note,
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
    return RenderedMedia(
      file,
      isVideo: true,
      durationMs: math.min(result.durationMs, maxVideoMs),
      poster: poster,
      width: outW,
      height: outH,
    );
  }
}

/// Un média rendu par [MediaExport.render] : le fichier, et pour une vidéo
/// sa durée et sa couverture.
class RenderedMedia {
  const RenderedMedia(
    this.file, {
    required this.isVideo,
    this.durationMs,
    this.poster,
    this.width,
    this.height,
  }) : assert(
         !isVideo || (durationMs != null && poster != null),
         'Une vidéo rendue porte sa durée et sa couverture',
       );
  final File file;
  final bool isVideo;
  final int? durationMs;
  final File? poster;
  final int? width;
  final int? height;
}
