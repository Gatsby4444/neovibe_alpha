import 'dart:io';
import 'dart:ui';

import 'color_grade.dart';
import 'media_edit.dart';
import 'overlay_model.dart';

/// **Une face éditée, écrite et relue telle quelle** — chaque cadrage,
/// chaque réglage, chaque calque (Brouillons, 2026-09-20). Les chemins de
/// fichiers sont absolus : ils pointent dans le dossier du brouillon, qui
/// possède ses fichiers (voir `DraftStore`, `VibeDraftKeeper`).
///
/// Une seule définition, éprouvée par un va-et-vient
/// (`test/media_edit_codec_test.dart`) : ce qui sort de [mediaFromJson] est
/// égal, champ à champ, à ce qui est entré dans [mediaToJson].
abstract final class MediaEditCodec {
  static Map<String, dynamic> mediaToJson(MediaEdit m) => {
    'id': m.id,
    'source': m.source.path,
    'isVideo': m.isVideo,
    'srcWidth': m.srcWidth,
    'srcHeight': m.srcHeight,
    'rotation': m.rotation,
    'durationMs': m.durationMs,
    'crop': {
      'zoom': m.crop.zoom,
      'cx': m.crop.cx,
      'cy': m.crop.cy,
      'angle': m.crop.angle,
      'turns': m.crop.turns,
    },
    'filter': m.filter.name,
    'filterStrength': m.filterStrength,
    'adjust': _grade(m.adjust),
    'overlays': [for (final o in m.overlays) _overlay(o)],
    'trim': m.trim == null
        ? null
        : {
            'startMs': m.trim!.startMs,
            'endMs': m.trim!.endMs,
            'coverMs': m.trim!.coverMs,
          },
  };

  static MediaEdit mediaFromJson(Map<String, dynamic> j) {
    final crop = (j['crop'] as Map).cast<String, dynamic>();
    final trim = (j['trim'] as Map?)?.cast<String, dynamic>();
    return MediaEdit(
      id: j['id'] as String,
      source: File(j['source'] as String),
      isVideo: j['isVideo'] as bool,
      srcWidth: (j['srcWidth'] as num).toInt(),
      srcHeight: (j['srcHeight'] as num).toInt(),
      rotation: (j['rotation'] as num?)?.toInt() ?? 0,
      durationMs: (j['durationMs'] as num?)?.toInt(),
      crop: CropSpec(
        zoom: (crop['zoom'] as num).toDouble(),
        cx: (crop['cx'] as num).toDouble(),
        cy: (crop['cy'] as num).toDouble(),
        angle: (crop['angle'] as num).toDouble(),
        turns: (crop['turns'] as num).toInt(),
      ),
      filter: MediaFilter.values.byName(j['filter'] as String),
      filterStrength: (j['filterStrength'] as num).toDouble(),
      adjust: _gradeFrom((j['adjust'] as Map).cast<String, dynamic>()),
      overlays: [
        for (final o in j['overlays'] as List)
          _overlayFrom((o as Map).cast<String, dynamic>()),
      ],
      trim: trim == null
          ? null
          : VideoTrim(
              startMs: (trim['startMs'] as num).toInt(),
              endMs: (trim['endMs'] as num).toInt(),
              coverMs: (trim['coverMs'] as num).toInt(),
            ),
    );
  }

  static Map<String, dynamic> _grade(ColorGrade g) => {
    'brightness': g.brightness,
    'contrast': g.contrast,
    'saturation': g.saturation,
    'warmth': g.warmth,
    'tint': g.tint,
    'fade': g.fade,
    'vignette': g.vignette,
    'shadows': g.shadows,
    'highlights': g.highlights,
    'sharpen': g.sharpen,
    'lux': g.lux,
  };

  static ColorGrade _gradeFrom(Map<String, dynamic> j) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    return ColorGrade(
      brightness: d('brightness'),
      contrast: d('contrast'),
      saturation: d('saturation'),
      warmth: d('warmth'),
      tint: d('tint'),
      fade: d('fade'),
      vignette: d('vignette'),
      shadows: d('shadows'),
      highlights: d('highlights'),
      sharpen: d('sharpen'),
      lux: d('lux'),
    );
  }

  static Map<String, dynamic> _overlay(OverlayObject o) => {
    'id': o.id,
    'cx': o.cx,
    'cy': o.cy,
    'scale': o.scale,
    'rotation': o.rotation,
    ...switch (o) {
      TextOverlay(
        :final text,
        :final font,
        :final color,
        :final backdrop,
        :final alignment,
      ) =>
        {
          'type': 'text',
          'text': text,
          'font': font.name,
          'color': color.toARGB32(),
          'backdrop': backdrop.name,
          'alignment': alignment.name,
        },
      StickerOverlay(:final emoji, :final imagePath) => {
        'type': 'sticker',
        'emoji': emoji,
        'imagePath': imagePath,
      },
    },
  };

  static OverlayObject _overlayFrom(Map<String, dynamic> j) {
    final id = j['id'] as String;
    final cx = (j['cx'] as num).toDouble();
    final cy = (j['cy'] as num).toDouble();
    final scale = (j['scale'] as num).toDouble();
    final rotation = (j['rotation'] as num).toDouble();
    return switch (j['type'] as String) {
      'text' => TextOverlay(
        id: id,
        text: j['text'] as String,
        font: OverlayFont.values.byName(j['font'] as String),
        color: Color((j['color'] as num).toInt()),
        backdrop: TextBackdrop.values.byName(j['backdrop'] as String),
        alignment: TextAlignment.values.byName(j['alignment'] as String),
        cx: cx,
        cy: cy,
        scale: scale,
        rotation: rotation,
      ),
      _ => StickerOverlay(
        id: id,
        emoji: j['emoji'] as String?,
        imagePath: j['imagePath'] as String?,
        cx: cx,
        cy: cy,
        scale: scale,
        rotation: rotation,
      ),
    };
  }
}
