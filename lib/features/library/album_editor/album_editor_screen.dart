import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/models/library_item.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../cards/native_media.dart';
import 'album_caption_screen.dart';
import 'album_draft.dart';
import 'album_export.dart';
import 'album_picker.dart';
import 'color_grade.dart';

/// **L'éditeur d'album** — « digne d'Instagram », sans les musiques (Jay,
/// 2026-09-15).
///
/// En haut, l'aperçu du média courant dans le cadre du ratio commun : on le
/// déplace au doigt et on le zoome à deux doigts. En bas, la bande des
/// médias, réordonnable (appui long), avec « + ». Entre les deux, les outils :
/// **Cadrer** (le ratio), **Filtres** (les presets), **Réglages** (les
/// curseurs), et pour une vidéo **Rogner** (début, fin, couverture).
///
/// L'écran ne calcule rien : il lit et modifie un [AlbumDraft] (pur), et
/// l'aperçu applique la même matrice et le même voile que l'export
/// (`ColorGrade`, `AlbumExport.vignettePaint`). Ce qu'on voit est ce qui sort.
///
/// Rend le brouillon prêt à publier, ou `null` si l'utilisateur renonce.
class AlbumEditorScreen extends StatefulWidget {
  const AlbumEditorScreen({super.key, required this.draft});

  final AlbumDraft draft;

  @override
  State<AlbumEditorScreen> createState() => _AlbumEditorScreenState();
}

enum _Tool { cadrer, filtres, reglages, rogner }

class _AlbumEditorScreenState extends State<AlbumEditorScreen> {
  late AlbumDraft _draft = widget.draft;
  var _current = 0;
  var _tool = _Tool.cadrer;

  /// Les vignettes des vidéos (une image extraite), par identifiant.
  final _videoThumbs = <String, Future<File?>>{};

  AlbumDraftMedia get _media => _draft.media[_current];

  Future<File?> _thumbOf(AlbumDraftMedia m) {
    if (!m.isVideo) return Future.value(m.source);
    return _videoThumbs.putIfAbsent(m.id, () async {
      final temp = await getTemporaryDirectory();
      final dest = File('${temp.path}/album_thumb_${m.id}.jpg');
      final ok = await NativeMedia.videoThumbnail(
        source: m.source.path,
        dest: dest.path,
        width: 320,
        atMs: m.effectiveTrim.startMs,
      );
      return ok ? dest : null;
    });
  }

  void _update(AlbumDraftMedia Function(AlbumDraftMedia) f) =>
      setState(() => _draft = _draft.update(_media.id, f));

  Future<void> _add() async {
    final more = await AlbumPicker.pick(context, freeSlots: _draft.freeSlots);
    if (more.isEmpty || !mounted) return;
    setState(() {
      _draft = _draft.add(more);
      _current = _draft.media.length - 1;
    });
  }

  void _remove() {
    if (_draft.media.length == 1) {
      // Retirer le dernier média, c'est renoncer.
      _close();
      return;
    }
    setState(() {
      _draft = _draft.remove(_media.id);
      _current = _current.clamp(0, _draft.media.length - 1);
    });
  }

  Future<void> _close() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandonner cette publication ?'),
        content: const Text('Les retouches seront perdues.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _next() async {
    final result = await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        builder: (_) => AlbumCaptionScreen(
          draft: _draft,
          coverThumb: _thumbOf(_draft.media.first),
        ),
      ),
    );
    if (result != null && mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final media = _media;
    final tools = [
      _Tool.cadrer,
      _Tool.filtres,
      _Tool.reglages,
      if (media.isVideo) _Tool.rogner,
    ];
    if (!tools.contains(_tool)) _tool = _Tool.cadrer;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Abandonner',
            onPressed: _close,
          ),
          title: const Text('Modifier'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Retirer ce média',
              onPressed: _remove,
            ),
            TextButton(onPressed: _next, child: const Text('Suivant')),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: AspectRatio(
                  aspectRatio: _draft.aspect.ratio,
                  child: _Preview(
                    // Une clé par média : changer de média reconstruit
                    // l'aperçu (et son lecteur vidéo) au lieu de le recycler.
                    key: ValueKey(media.id),
                    media: media,
                    aspect: _draft.aspect,
                    onCrop: (c) => _update((m) => m.copyWith(crop: c)),
                  ),
                ),
              ),
            ),
            _Strip(
              draft: _draft,
              current: _current,
              thumbOf: _thumbOf,
              onSelect: (i) => setState(() => _current = i),
              onReorder: (from, to) => setState(() {
                final id = _media.id;
                _draft = _draft.reorder(from, to);
                _current = _draft.media.indexWhere((m) => m.id == id);
              }),
              onAdd: _draft.isFull ? null : _add,
            ),
            _ToolBar(
              tools: tools,
              current: _tool,
              onChanged: (t) => setState(() => _tool = t),
            ),
            SizedBox(
              height: 128,
              child: switch (_tool) {
                _Tool.cadrer => _CropPanel(
                  aspect: _draft.aspect,
                  onAspect: (a) =>
                      setState(() => _draft = _draft.withAspect(a)),
                  onReset: () =>
                      _update((m) => m.copyWith(crop: CropSpec.none)),
                ),
                _Tool.filtres => _FilterPanel(
                  media: media,
                  thumb: _thumbOf(media),
                  onFilter: (f) => _update((m) => m.copyWith(filter: f)),
                ),
                _Tool.reglages => _AdjustPanel(
                  adjust: media.adjust,
                  onAdjust: (a) => _update((m) => m.copyWith(adjust: a)),
                ),
                _Tool.rogner => _TrimPanel(
                  media: media,
                  onTrim: (t) => _update((m) => m.copyWith(trim: t)),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// L'aperçu : le cadre, le média dedans, les gestes de recadrage
// ---------------------------------------------------------------------------

class _Preview extends StatefulWidget {
  const _Preview({
    super.key,
    required this.media,
    required this.aspect,
    required this.onCrop,
  });

  final AlbumDraftMedia media;
  final AlbumAspect aspect;
  final ValueChanged<CropSpec> onCrop;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  double _lastScale = 1;

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameW = constraints.maxWidth;
        final frameH = constraints.maxHeight;
        final src = m.crop.sourceRect(
          m.srcWidth,
          m.srcHeight,
          widget.aspect.ratio,
        );
        // Le cadre montre `src` étiré sur toute sa largeur : l'image entière
        // est donc dessinée à cette échelle, décalée pour que `src` tombe
        // sur le cadre.
        final scale = frameW / src.width;
        return GestureDetector(
          onScaleStart: (_) => _lastScale = 1,
          onScaleUpdate: (d) {
            var crop = m.crop;
            if (d.scale != _lastScale) {
              crop = crop.zoomed(
                d.scale / _lastScale,
                srcW: m.srcWidth,
                srcH: m.srcHeight,
                aspect: widget.aspect.ratio,
              );
              _lastScale = d.scale;
            }
            crop = crop.panned(
              d.focalPointDelta.dx,
              d.focalPointDelta.dy,
              srcW: m.srcWidth,
              srcH: m.srcHeight,
              aspect: widget.aspect.ratio,
              frameW: frameW,
              frameH: frameH,
            );
            widget.onCrop(crop);
          },
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: -src.left * scale,
                  top: -src.top * scale,
                  width: m.srcWidth * scale,
                  height: m.srcHeight * scale,
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(m.grade.toMatrix()),
                    child: m.isVideo
                        ? _VideoPreview(media: m)
                        : Image.file(
                            m.source,
                            fit: BoxFit.fill,
                            // Assez pour l'écran, jamais les 12 Mpx d'origine.
                            cacheWidth: 1440,
                            gaplessPlayback: true,
                          ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _VignettePainter(m.grade.vignette),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Le même voile qu'à l'export (`AlbumExport.vignettePaint`).
class _VignettePainter extends CustomPainter {
  const _VignettePainter(this.vignette);
  final double vignette;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = AlbumExport.vignettePaint(rect, vignette);
    if (paint != null) canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_VignettePainter old) => old.vignette != vignette;
}

/// La vidéo source, en boucle sur le morceau rogné. Un lecteur ordinaire
/// (`video_player`) : le fichier est celui de l'utilisateur, en clair, avant
/// tout scellement — rien à protéger ici.
class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.media});
  final AlbumDraftMedia media;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    widget.media.source,
  );
  VideoTrim get _trim => widget.media.effectiveTrim;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller.setVolume(0);
      _controller.addListener(_boucle);
      _controller.seekTo(Duration(milliseconds: _trim.startMs));
      _controller.play();
      setState(() {});
    });
  }

  /// Arrivé à la fin du morceau, on repart de son début.
  void _boucle() {
    final v = _controller.value;
    if (!v.isInitialized) return;
    if (v.position.inMilliseconds >= _trim.endMs ||
        (!v.isPlaying && v.position >= v.duration)) {
      _controller.seekTo(Duration(milliseconds: _trim.startMs));
      _controller.play();
    }
  }

  @override
  void didUpdateWidget(covariant _VideoPreview old) {
    super.didUpdateWidget(old);
    if (old.media.effectiveTrim.startMs != _trim.startMs &&
        _controller.value.isInitialized) {
      _controller.seekTo(Duration(milliseconds: _trim.startMs));
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_boucle);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return VideoPlayer(_controller);
  }
}

// ---------------------------------------------------------------------------
// La bande des médias
// ---------------------------------------------------------------------------

class _Strip extends StatelessWidget {
  const _Strip({
    required this.draft,
    required this.current,
    required this.thumbOf,
    required this.onSelect,
    required this.onReorder,
    required this.onAdd,
  });

  final AlbumDraft draft;
  final int current;
  final Future<File?> Function(AlbumDraftMedia) thumbOf;
  final ValueChanged<int> onSelect;
  final void Function(int from, int to) onReorder;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 76,
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: NeoSpace.md,
                vertical: NeoSpace.sm,
              ),
              buildDefaultDragHandles: false,
              itemCount: draft.media.length,
              onReorderItem: onReorder,
              itemBuilder: (context, i) {
                final m = draft.media[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(m.id),
                  index: i,
                  child: GestureDetector(
                    onTap: () => onSelect(i),
                    child: Container(
                      width: 60,
                      margin: const EdgeInsets.only(right: NeoSpace.sm),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(NeoRadius.sm),
                        border: Border.all(
                          color: i == current ? accent : context.palette.line,
                          width: i == current ? 2 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _Thumb(thumb: thumbOf(m)),
                          if (m.isVideo)
                            const Positioned(
                              right: 3,
                              bottom: 3,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (onAdd != null)
            Padding(
              padding: const EdgeInsets.only(right: NeoSpace.md),
              child: IconButton.outlined(
                icon: const Icon(Icons.add),
                tooltip:
                    'Ajouter (${draft.freeSlots} place'
                    '${draft.freeSlots > 1 ? 's' : ''})',
                onPressed: onAdd,
              ),
            ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.thumb, this.grade});
  final Future<File?> thumb;
  final ColorGrade? grade;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: thumb,
      builder: (context, snap) {
        final file = snap.data;
        if (file == null) {
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          );
        }
        final image = Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: 200,
          gaplessPlayback: true,
        );
        return grade == null
            ? image
            : ColorFiltered(
                colorFilter: ColorFilter.matrix(grade!.toMatrix()),
                child: image,
              );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Les outils
// ---------------------------------------------------------------------------

class _ToolBar extends StatelessWidget {
  const _ToolBar({
    required this.tools,
    required this.current,
    required this.onChanged,
  });

  final List<_Tool> tools;
  final _Tool current;
  final ValueChanged<_Tool> onChanged;

  String _label(_Tool t) => switch (t) {
    _Tool.cadrer => 'Cadrer',
    _Tool.filtres => 'Filtres',
    _Tool.reglages => 'Réglages',
    _Tool.rogner => 'Rogner',
  };

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final t in tools)
          TextButton(
            onPressed: () => onChanged(t),
            style: TextButton.styleFrom(
              foregroundColor: t == current ? accent : context.muted,
            ),
            child: Text(
              _label(t),
              style: TextStyle(
                fontWeight: t == current ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}

class _CropPanel extends StatelessWidget {
  const _CropPanel({
    required this.aspect,
    required this.onAspect,
    required this.onReset,
  });

  final AlbumAspect aspect;
  final ValueChanged<AlbumAspect> onAspect;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SegmentedButton<AlbumAspect>(
          segments: [
            for (final a in AlbumAspect.values)
              ButtonSegment(value: a, label: Text(a.label)),
          ],
          selected: {aspect},
          onSelectionChanged: (s) => onAspect(s.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: NeoSpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Glisse pour cadrer · pince pour zoomer',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            TextButton(onPressed: onReset, child: const Text('Réinitialiser')),
          ],
        ),
      ],
    );
  }
}

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.media,
    required this.thumb,
    required this.onFilter,
  });

  final AlbumDraftMedia media;
  final Future<File?> thumb;
  final ValueChanged<AlbumFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: NeoSpace.md,
        vertical: NeoSpace.sm,
      ),
      itemCount: AlbumFilter.values.length,
      itemBuilder: (context, i) {
        final f = AlbumFilter.values[i];
        final selected = f == media.filter;
        return GestureDetector(
          onTap: () => onFilter(f),
          child: Padding(
            padding: const EdgeInsets.only(right: NeoSpace.md),
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(NeoRadius.sm),
                    border: Border.all(
                      color: selected ? accent : context.palette.line,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  // Chaque puce montre CE média à travers CE filtre : c'est
                  // la même matrice que l'aperçu et que l'export.
                  child: _Thumb(thumb: thumb, grade: f.grade),
                ),
                const SizedBox(height: 4),
                Text(
                  f.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? accent : context.muted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _Knob {
  brightness('Luminosité', -1, 1),
  contrast('Contraste', -1, 1),
  saturation('Saturation', -1, 1),
  warmth('Chaleur', -1, 1),
  tint('Teinte', -1, 1),
  fade('Fondu', 0, 1),
  vignette('Vignette', 0, 1);

  const _Knob(this.label, this.min, this.max);
  final String label;
  final double min;
  final double max;

  double of(ColorGrade g) => switch (this) {
    brightness => g.brightness,
    contrast => g.contrast,
    saturation => g.saturation,
    warmth => g.warmth,
    tint => g.tint,
    fade => g.fade,
    vignette => g.vignette,
  };

  ColorGrade set(ColorGrade g, double v) => switch (this) {
    brightness => g.copyWith(brightness: v),
    contrast => g.copyWith(contrast: v),
    saturation => g.copyWith(saturation: v),
    warmth => g.copyWith(warmth: v),
    tint => g.copyWith(tint: v),
    fade => g.copyWith(fade: v),
    vignette => g.copyWith(vignette: v),
  };
}

class _AdjustPanel extends StatefulWidget {
  const _AdjustPanel({required this.adjust, required this.onAdjust});

  final ColorGrade adjust;
  final ValueChanged<ColorGrade> onAdjust;

  @override
  State<_AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends State<_AdjustPanel> {
  var _knob = _Knob.brightness;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final value = _knob.of(widget.adjust);
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
            children: [
              for (final k in _Knob.values)
                Padding(
                  padding: const EdgeInsets.only(right: NeoSpace.sm),
                  child: ChoiceChip(
                    label: Text(k.label),
                    selected: k == _knob,
                    // Un point sur les réglages touchés, pour les retrouver.
                    avatar: k.of(widget.adjust) != 0 && k != _knob
                        ? Icon(Icons.circle, size: 6, color: accent)
                        : null,
                    onSelected: (_) => setState(() => _knob = k),
                  ),
                ),
            ],
          ),
        ),
        Row(
          children: [
            const SizedBox(width: NeoSpace.md),
            Expanded(
              child: Slider(
                value: value,
                min: _knob.min,
                max: _knob.max,
                onChanged: (v) => widget.onAdjust(_knob.set(widget.adjust, v)),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${(value * 100).round()}',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted, fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.restart_alt, size: 20),
              tooltip: 'Remettre à zéro',
              onPressed: value == 0
                  ? null
                  : () => widget.onAdjust(_knob.set(widget.adjust, 0)),
            ),
          ],
        ),
      ],
    );
  }
}

class _TrimPanel extends StatefulWidget {
  const _TrimPanel({required this.media, required this.onTrim});

  final AlbumDraftMedia media;
  final ValueChanged<VideoTrim> onTrim;

  @override
  State<_TrimPanel> createState() => _TrimPanelState();
}

class _TrimPanelState extends State<_TrimPanel> {
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
        '${temp.path}/album_cover_${widget.media.id}_${t.coverMs}.jpg',
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
    final m = widget.media;
    final duration = m.durationMs!.toDouble();
    final t = m.effectiveTrim;
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: NeoSpace.md),
            Text(
              _mmss(t.startMs),
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            Expanded(
              child: RangeSlider(
                values: RangeValues(t.startMs.toDouble(), t.endMs.toDouble()),
                min: 0,
                max: duration,
                onChanged: (v) {
                  var s = v.start.round();
                  var e = v.end.round();
                  // Au plus 60 s : la borne qu'on n'a pas touchée suit.
                  if (e - s > kAlbumMaxVideoMs) {
                    if (s != t.startMs) {
                      e = s + kAlbumMaxVideoMs;
                    } else {
                      s = e - kAlbumMaxVideoMs;
                    }
                  }
                  final n = t
                      .copyWith(startMs: s, endMs: e)
                      .normalized(m.durationMs!);
                  widget.onTrim(n);
                },
              ),
            ),
            Text(
              _mmss(t.endMs),
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
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
                border: Border.all(color: context.palette.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: _cover == null
                  ? const SizedBox.shrink()
                  : _Thumb(thumb: _cover!),
            ),
            const SizedBox(width: NeoSpace.sm),
            Text(
              'Couverture',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
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
            Text(
              '${((t.endMs - t.startMs) / 1000).round()} s',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            const SizedBox(width: NeoSpace.md),
          ],
        ),
      ],
    );
  }
}
