import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/typography.dart';
import '../native_media.dart';
import 'media_edit.dart';
import 'color_grade.dart';
import 'editor_images.dart';
import 'editor_theme.dart';
import 'grade_shader.dart';
import 'overlay_model.dart';

/// **Les panneaux de l'éditeur de Vibes** (`VibeEditorScreen`) — écrits
/// d'abord pour l'éditeur d'album (2026-09-15), repris tels quels par celui
/// des Vibes le 2026-09-18 (Jay : *« inspire-toi de celui qu'on a créé pour
/// les Flows »*). Les albums et les Flows sont sortis du MVP le 2026-09-21 ;
/// les panneaux restent, avec un seul éditeur.

/// Les outils de la barre du bas.
enum EditorTool { texte, sticker, filtre, modifier, rogner }

// ---------------------------------------------------------------------------
// Les outils de texte, pendant l'écriture sur l'image
// ---------------------------------------------------------------------------

enum _TextRow { fonts, colors }

/// Police · couleur · alignement · fond — la rangée des polices ou des
/// couleurs au-dessus, comme sur Instagram. Ce que l'utilisateur change ici
/// se voit tout de suite dans le champ posé sur l'image.
class TextToolsPanel extends StatefulWidget {
  const TextToolsPanel({
    super.key,
    required this.overlay,
    required this.onChanged,
  });

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;

  @override
  State<TextToolsPanel> createState() => _TextToolsPanelState();
}

class _TextToolsPanelState extends State<TextToolsPanel> {
  var _row = _TextRow.fonts;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final o = widget.overlay;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: switch (_row) {
              _TextRow.fonts => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: NeoSpace.md,
                  vertical: NeoSpace.sm,
                ),
                children: [
                  for (final f in OverlayFont.values)
                    Padding(
                      padding: const EdgeInsets.only(right: NeoSpace.sm),
                      child: ChoiceChip(
                        label: Text(
                          f.label,
                          style: TextStyle(
                            fontFamily: f.family,
                            fontWeight: FontWeight
                                .values[(f.weight ~/ 100 - 1).clamp(0, 8)],
                          ),
                        ),
                        selected: f == o.font,
                        showCheckmark: false,
                        onSelected: (_) =>
                            widget.onChanged(o.copyWith(font: f)),
                      ),
                    ),
                ],
              ),
              _TextRow.colors => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: NeoSpace.md,
                  vertical: NeoSpace.sm,
                ),
                children: [
                  for (final col in OverlayColors.swatches)
                    GestureDetector(
                      onTap: () => widget.onChanged(o.copyWith(color: col)),
                      child: Container(
                        width: 36,
                        height: 36,
                        margin: const EdgeInsets.only(right: NeoSpace.sm),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: col,
                          border: Border.all(
                            color: col == o.color ? c.accent : c.line,
                            width: col == o.color ? 3 : 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.md,
              NeoSpace.xs,
              NeoSpace.md,
              NeoSpace.md,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _TextToolButton(
                  icon: Icons.text_fields,
                  active: _row == _TextRow.fonts,
                  tooltip: 'Police',
                  onTap: () => setState(() => _row = _TextRow.fonts),
                ),
                _TextToolButton(
                  icon: Icons.palette_outlined,
                  active: _row == _TextRow.colors,
                  tooltip: 'Couleur',
                  onTap: () => setState(() => _row = _TextRow.colors),
                ),
                _TextToolButton(
                  icon: switch (o.alignment) {
                    TextAlignment.left => Icons.format_align_left,
                    TextAlignment.center => Icons.format_align_center,
                    TextAlignment.right => Icons.format_align_right,
                  },
                  tooltip: 'Alignement',
                  onTap: () => widget.onChanged(
                    o.copyWith(
                      alignment:
                          TextAlignment.values[(o.alignment.index + 1) %
                              TextAlignment.values.length],
                    ),
                  ),
                ),
                _TextToolButton(
                  icon: switch (o.backdrop) {
                    TextBackdrop.none => Icons.font_download_outlined,
                    TextBackdrop.solid => Icons.font_download,
                    TextBackdrop.translucent =>
                      Icons.font_download_off_outlined,
                  },
                  active: o.backdrop != TextBackdrop.none,
                  tooltip: 'Fond',
                  onTap: () => widget.onChanged(
                    o.copyWith(
                      backdrop:
                          TextBackdrop.values[(o.backdrop.index + 1) %
                              TextBackdrop.values.length],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TextToolButton extends StatelessWidget {
  const _TextToolButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NeoSpace.sm),
      child: Material(
        color: active ? c.accent : c.raised,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Tooltip(
            message: tooltip,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, color: active ? c.onAccent : c.ink),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// La barre d'outils, et le panneau
// ---------------------------------------------------------------------------

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({super.key, required this.video, required this.onTool});

  final bool video;
  final ValueChanged<EditorTool> onTool;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final tools = [
      (EditorTool.texte, Icons.text_fields, 'Texte'),
      (EditorTool.sticker, Icons.emoji_emotions_outlined, 'Superposition'),
      (EditorTool.filtre, Icons.auto_awesome_outlined, 'Filtre'),
      (EditorTool.modifier, Icons.tune, 'Modifier'),
      if (video) (EditorTool.rogner, Icons.content_cut, 'Rogner'),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NeoSpace.md,
          NeoSpace.sm,
          NeoSpace.md,
          NeoSpace.md,
        ),
        child: Row(
          children: [
            for (var i = 0; i < tools.length; i++) ...[
              if (i > 0) const SizedBox(width: NeoSpace.sm),
              Expanded(
                child: Material(
                  color: c.raised,
                  borderRadius: BorderRadius.circular(NeoRadius.md),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onTool(tools[i].$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: NeoSpace.sm,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(tools[i].$2, size: 22, color: c.ink),
                          const SizedBox(height: 4),
                          Text(
                            tools[i].$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: c.ink),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Un panneau d'outil : son contenu, puis **Annuler · Titre · Terminé** en
/// bas, comme sur Instagram.
class EditorPanel extends StatelessWidget {
  const EditorPanel({
    super.key,
    required this.title,
    required this.onCancel,
    required this.onDone,
    required this.child,
  });

  final String title;
  final VoidCallback onCancel;
  final VoidCallback onDone;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 168, child: child),
          Row(
            children: [
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
                ),
                child: const Text('Annuler'),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: NeoType.display,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: c.ink,
                  ),
                ),
              ),
              TextButton(
                onPressed: onDone,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
                ),
                child: const Text(
                  'Terminé',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: NeoSpace.xs),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filtre — les puces, et l'intensité au second tap
// ---------------------------------------------------------------------------

class FilterPanel extends StatefulWidget {
  const FilterPanel({
    super.key,
    required this.media,
    required this.images,
    required this.onChanged,
  });

  final MediaEdit media;
  final EditorImages images;
  final void Function(MediaFilter filter, double strength) onChanged;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  ui.Image? _small;
  var _tuning = false;

  @override
  void initState() {
    super.initState();
    widget.images.small(widget.media).then((img) {
      if (mounted) setState(() => _small = img);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final accent = c.accent;
    final m = widget.media;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: _tuning && m.filter != MediaFilter.normal
              ? Row(
                  children: [
                    const SizedBox(width: NeoSpace.lg),
                    Expanded(
                      child: Slider(
                        value: m.filterStrength,
                        onChanged: (v) => widget.onChanged(m.filter, v),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${(m.filterStrength * 100).round()}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.inkMuted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: NeoSpace.sm),
                  ],
                )
              : Center(
                  child: Text(
                    m.filter == MediaFilter.normal
                        ? 'Choisis un filtre'
                        : 'Appuie à nouveau pour ajuster',
                    style: TextStyle(color: c.inkFaint, fontSize: 12),
                  ),
                ),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
            itemCount: MediaFilter.values.length,
            itemBuilder: (context, i) {
              final f = MediaFilter.values[i];
              final selected = f == m.filter;
              return GestureDetector(
                onTap: () {
                  if (selected) {
                    setState(() => _tuning = !_tuning);
                  } else {
                    setState(() => _tuning = false);
                    widget.onChanged(f, 1);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.only(right: NeoSpace.md),
                  child: Column(
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(NeoRadius.sm),
                          border: Border.all(
                            color: selected ? accent : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        // Chaque puce montre CE média à travers CE filtre, par
                        // le même shader que l'aperçu et que l'export.
                        child: _small == null
                            ? ColoredBox(color: c.raised)
                            : CustomPaint(
                                painter: GradedThumbPainter(
                                  image: _small!,
                                  media: m,
                                  aspect: 1,
                                  grade: f.grade,
                                ),
                              ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        f.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected ? accent : c.inkMuted,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Modifier — les réglages en ronds, un curseur pour celui qu'on touche
// ---------------------------------------------------------------------------

enum _Knob {
  straighten('Redresser', Icons.crop_rotate, -45, 45),
  lux('Lux', Icons.auto_fix_high, 0, 1),
  brightness('Luminosité', Icons.wb_sunny_outlined, -1, 1),
  contrast('Contraste', Icons.contrast, -1, 1),
  warmth('Chaleur', Icons.thermostat, -1, 1),
  saturation('Saturation', Icons.water_drop_outlined, -1, 1),
  tint('Teinte', Icons.color_lens_outlined, -1, 1),
  highlights('Hautes lumières', Icons.light_mode_outlined, -1, 1),
  shadows('Ombres', Icons.dark_mode_outlined, -1, 1),
  fade('Fondu', Icons.cloud_outlined, 0, 1),
  vignette('Vignette', Icons.vignette_outlined, 0, 1),
  sharpen('Netteté', Icons.change_history, 0, 1);

  const _Knob(this.label, this.icon, this.min, this.max);
  final String label;
  final IconData icon;
  final double min;
  final double max;

  double of(MediaEdit m) => switch (this) {
    straighten => m.crop.angle,
    lux => m.adjust.lux,
    brightness => m.adjust.brightness,
    contrast => m.adjust.contrast,
    warmth => m.adjust.warmth,
    saturation => m.adjust.saturation,
    tint => m.adjust.tint,
    highlights => m.adjust.highlights,
    shadows => m.adjust.shadows,
    fade => m.adjust.fade,
    vignette => m.adjust.vignette,
    sharpen => m.adjust.sharpen,
  };

  ColorGrade set(ColorGrade g, double v) => switch (this) {
    straighten => g,
    lux => g.copyWith(lux: v),
    brightness => g.copyWith(brightness: v),
    contrast => g.copyWith(contrast: v),
    warmth => g.copyWith(warmth: v),
    saturation => g.copyWith(saturation: v),
    tint => g.copyWith(tint: v),
    highlights => g.copyWith(highlights: v),
    shadows => g.copyWith(shadows: v),
    fade => g.copyWith(fade: v),
    vignette => g.copyWith(vignette: v),
    sharpen => g.copyWith(sharpen: v),
  };

  /// Ce que le curseur affiche : des degrés, ou un pourcentage.
  String display(double v) =>
      this == straighten ? '${v.round()}°' : '${(v * 100).round()}';
}

class AdjustPanel extends StatefulWidget {
  const AdjustPanel({
    super.key,
    required this.media,
    required this.onAdjust,
    required this.onCrop,
  });

  final MediaEdit media;
  final ValueChanged<ColorGrade> onAdjust;
  final ValueChanged<CropSpec> onCrop;

  @override
  State<AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends State<AdjustPanel> {
  _Knob? _knob;

  void _set(_Knob k, double v) {
    if (k == _Knob.straighten) {
      widget.onCrop(widget.media.crop.copyWith(angle: v));
    } else {
      widget.onAdjust(k.set(widget.media.adjust, v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final accent = c.accent;
    final m = widget.media;
    final k = _knob;
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: k == null
              ? Center(
                  child: Text(
                    'Touche un réglage',
                    style: TextStyle(color: c.inkFaint, fontSize: 12),
                  ),
                )
              : Row(
                  children: [
                    const SizedBox(width: NeoSpace.md),
                    if (k == _Knob.straighten)
                      IconButton(
                        icon: Icon(Icons.rotate_90_degrees_cw_outlined),
                        tooltip: 'Tourner d\'un quart de tour',
                        onPressed: () => widget.onCrop(m.crop.turned()),
                      ),
                    Expanded(
                      child: Slider(
                        value: k.of(m).clamp(k.min, k.max),
                        min: k.min,
                        max: k.max,
                        onChanged: (v) => _set(k, v),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        k.display(k.of(m)),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.inkMuted, fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.restart_alt, size: 20),
                      tooltip: 'Remettre à zéro',
                      onPressed: k.of(m) == 0 ? null : () => _set(k, 0),
                    ),
                  ],
                ),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
            itemCount: _Knob.values.length,
            itemBuilder: (context, i) {
              final knob = _Knob.values[i];
              final active = knob == k;
              final touched = knob.of(m) != 0;
              return GestureDetector(
                onTap: () => setState(() => _knob = knob),
                child: Padding(
                  padding: const EdgeInsets.only(right: NeoSpace.lg),
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? Colors.white : Colors.transparent,
                          border: Border.all(
                            color: active ? Colors.white : c.inkMuted,
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          knob.icon,
                          size: 26,
                          color: active ? Colors.black : c.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        knob.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: active ? c.ink : c.inkMuted,
                        ),
                      ),
                      // Un point sous les réglages touchés, pour les retrouver.
                      Container(
                        width: 5,
                        height: 5,
                        margin: const EdgeInsets.only(top: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: touched ? accent : Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rogner — début, fin, couverture (vidéo)
// ---------------------------------------------------------------------------

class TrimPanel extends StatefulWidget {
  const TrimPanel({
    super.key,
    required this.media,
    required this.onTrim,
    this.maxMs = kMaxFaceVideoMs,
  });

  final MediaEdit media;
  final ValueChanged<VideoTrim> onTrim;

  /// Une face vidéo dure au plus une minute.
  final int maxMs;

  @override
  State<TrimPanel> createState() => _TrimPanelState();
}

class _TrimPanelState extends State<TrimPanel> {
  Timer? _debounce;
  Future<File?>? _cover;

  static String _mmss(int ms) {
    final s = (ms / 1000).round();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  void _refreshCover(VideoTrim t) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final temp = await getTemporaryDirectory();
      final dest = File(
        '${temp.path}/face_cover_${widget.media.id}_${t.coverMs}.jpg',
      );
      final ok = await NativeMedia.videoThumbnail(
        source: widget.media.source.path,
        dest: dest.path,
        width: 240,
        atMs: t.coverMs,
      );
      if (mounted) setState(() => _cover = Future.value(ok ? dest : null));
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshCover(widget.media.effectiveTrim);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final m = widget.media;
    final duration = m.durationMs!.toDouble();
    final t = m.effectiveTrim;
    final label = TextStyle(color: c.inkMuted, fontSize: 12);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            const SizedBox(width: NeoSpace.md),
            Text(_mmss(t.startMs), style: label),
            Expanded(
              child: RangeSlider(
                values: RangeValues(t.startMs.toDouble(), t.endMs.toDouble()),
                min: 0,
                max: duration,
                onChanged: (v) {
                  var s = v.start.round();
                  var e = v.end.round();
                  // Au plus la limite du format : la borne qu'on n'a pas
                  // touchée suit.
                  if (e - s > widget.maxMs) {
                    if (s != t.startMs) {
                      e = s + widget.maxMs;
                    } else {
                      s = e - widget.maxMs;
                    }
                  }
                  widget.onTrim(
                    t
                        .copyWith(startMs: s, endMs: e)
                        .normalized(m.durationMs!, maxMs: widget.maxMs),
                  );
                },
              ),
            ),
            Text(_mmss(t.endMs), style: label),
            const SizedBox(width: NeoSpace.md),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: NeoSpace.md),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NeoRadius.sm),
                border: Border.all(color: c.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: _cover == null
                  ? const SizedBox.shrink()
                  : FileThumb(thumb: _cover!),
            ),
            const SizedBox(width: NeoSpace.sm),
            Text('Couverture', style: label),
            Expanded(
              child: Slider(
                value: t.coverMs.toDouble().clamp(
                  t.startMs.toDouble(),
                  (t.endMs - 1).toDouble(),
                ),
                min: t.startMs.toDouble(),
                max: (t.endMs - 1).toDouble(),
                onChanged: (v) {
                  final n = t.copyWith(coverMs: v.round());
                  widget.onTrim(n);
                  _refreshCover(n);
                },
              ),
            ),
            Text('${((t.endMs - t.startMs) / 1000).round()} s', style: label),
            const SizedBox(width: NeoSpace.md),
          ],
        ),
      ],
    );
  }
}

/// Une vignette-fichier : la source d'une photo, ou l'image extraite d'une
/// vidéo. Un rectangle de la couleur de l'éditeur tant qu'elle n'est pas là.
class FileThumb extends StatelessWidget {
  const FileThumb({super.key, required this.thumb});
  final Future<File?> thumb;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return FutureBuilder<File?>(
      future: thumb,
      builder: (context, snap) {
        final file = snap.data;
        if (file == null) return ColoredBox(color: c.raised);
        return Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: 200,
          gaplessPlayback: true,
        );
      },
    );
  }
}
