import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'album_draft.dart';
import 'color_grade.dart';
import 'crop_geometry.dart';
import 'editor_images.dart';
import 'editor_theme.dart';
import 'grade_shader.dart';
import 'overlay_model.dart';
import 'overlay_painter.dart';

/// **L'aperçu d'un média dans le cadre**, avec ses gestes.
///
/// - Une **photo** est peinte par le shader (`GradePainter`) : cadrage,
///   rotation, filtre, réglages, vignette — exactement ce que l'export produira.
/// - Une **vidéo** joue dans un lecteur ordinaire posé sous le cadre par la
///   même géométrie (`CropGeometry.matrix`), à travers la matrice de couleurs
///   et le voile de vignette. Ombres, hautes lumières et netteté ne se voient
///   pas sur l'aperçu vidéo (le lecteur ne passe pas par notre shader) ; elles
///   s'appliquent au rendu final.
/// - Les **calques** (textes, autocollants) sont dessinés par-dessus par le
///   même peintre que l'export.
///
/// Gestes : un doigt posé sur un calque le déplace ; deux doigts le zooment
/// et le tournent. Ailleurs, un doigt cadre l'image, deux la zooment. Un tap
/// sur un calque le sélectionne (et, pour un texte, l'ouvre à la retouche) ;
/// un calque lâché sur la corbeille est retiré.
class MediaPreview extends StatefulWidget {
  const MediaPreview({
    super.key,
    required this.media,
    required this.aspect,
    required this.images,
    required this.selectedOverlayId,
    required this.onCrop,
    required this.onOverlayChanged,
    required this.onOverlaySelected,
    required this.onOverlayTapped,
    required this.onOverlayRemoved,
  });

  final AlbumDraftMedia media;
  final double aspect;
  final EditorImages images;
  final String? selectedOverlayId;
  final ValueChanged<CropSpec> onCrop;
  final ValueChanged<OverlayObject> onOverlayChanged;
  final ValueChanged<String?> onOverlaySelected;
  final ValueChanged<OverlayObject> onOverlayTapped;
  final ValueChanged<String> onOverlayRemoved;

  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview> {
  ui.Image? _full;
  OverlayObject? _dragging;
  var _overTrash = false;
  double _lastScale = 1;
  double _lastRotation = 0;
  Size _frame = Size.zero;

  late final OverlayPainter _painter = OverlayPainter(
    images: (path) => widget.images.stickerReady(path),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MediaPreview old) {
    super.didUpdateWidget(old);
    if (old.media.id != widget.media.id ||
        (widget.media.isVideo &&
            old.media.effectiveTrim.startMs !=
                widget.media.effectiveTrim.startMs)) {
      _full = null;
      _load();
    }
    // Les images d'autocollants arrivent en différé : on redessine quand
    // elles sont là.
    for (final o in widget.media.overlays) {
      if (o is StickerOverlay && !o.isEmoji) {
        widget.images.sticker(o.imagePath!).then((_) {
          if (mounted) setState(() {});
        });
      }
    }
  }

  Future<void> _load() async {
    if (widget.media.isVideo) return;
    final m = widget.media;
    final img = await widget.images.full(m);
    if (mounted && widget.media.id == m.id) setState(() => _full = img);
  }

  // ── Gestes ──────────────────────────────────────────────────────────

  void _onTapUp(TapUpDetails d) {
    final hit = _painter.hitTest(
      _frame,
      widget.media.overlays,
      d.localPosition,
    );
    if (hit == null) {
      widget.onOverlaySelected(null);
      return;
    }
    widget.onOverlaySelected(hit.id);
    widget.onOverlayTapped(hit);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _lastScale = 1;
    _lastRotation = 0;
    _overTrash = false;
    final hit = _painter.hitTest(
      _frame,
      widget.media.overlays,
      d.localFocalPoint,
    );
    _dragging = hit;
    if (hit != null) widget.onOverlaySelected(hit.id);
    setState(() {});
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final dragging = _dragging;
    if (dragging != null) {
      final current = widget.media.overlays
          .where((o) => o.id == dragging.id)
          .firstOrNull;
      if (current == null) return;
      final next = current.gestured(
        frameW: _frame.width,
        frameH: _frame.height,
        delta: d.focalPointDelta,
        scaleFactor: d.scale / _lastScale,
        rotationDelta: d.rotation - _lastRotation,
      );
      _lastScale = d.scale;
      _lastRotation = d.rotation;
      final over = _trashRect.contains(d.localFocalPoint);
      if (over != _overTrash) setState(() => _overTrash = over);
      widget.onOverlayChanged(next);
      return;
    }
    var crop = widget.media.crop;
    final m = widget.media;
    if (d.scale != _lastScale) {
      crop = CropGeometry.zoomed(
        m.copyWith(crop: crop),
        widget.aspect,
        d.scale / _lastScale,
      );
      _lastScale = d.scale;
    }
    crop = CropGeometry.panned(
      m.copyWith(crop: crop),
      widget.aspect,
      d.focalPointDelta.dx,
      d.focalPointDelta.dy,
      frameW: _frame.width,
    );
    widget.onCrop(crop);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final dragging = _dragging;
    if (dragging != null && _overTrash) widget.onOverlayRemoved(dragging.id);
    setState(() {
      _dragging = null;
      _overTrash = false;
    });
  }

  Rect get _trashRect => Rect.fromCenter(
    center: Offset(_frame.width / 2, _frame.height - 44),
    width: 96,
    height: 72,
  );

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    return LayoutBuilder(
      builder: (context, constraints) {
        _frame = Size(constraints.maxWidth, constraints.maxHeight);
        final selected = widget.selectedOverlayId == null
            ? null
            : m.overlays
                  .where((o) => o.id == widget.selectedOverlayId)
                  .firstOrNull;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: EditorColors.surface),
                if (m.isVideo)
                  _TransformedMedia(
                    media: m,
                    aspect: widget.aspect,
                    frame: _frame,
                    child: _VideoPreview(media: m),
                  )
                else if (_full != null)
                  CustomPaint(
                    painter: GradePainter(
                      image: _full!,
                      media: m,
                      aspect: widget.aspect,
                    ),
                  )
                else
                  _TransformedMedia(
                    media: m,
                    aspect: widget.aspect,
                    frame: _frame,
                    child: Image.file(
                      m.source,
                      fit: BoxFit.fill,
                      cacheWidth: 800,
                      gaplessPlayback: true,
                    ),
                  ),
                // Les calques, par le même peintre que l'export.
                IgnorePointer(
                  child: CustomPaint(
                    painter: OverlaysPainter(
                      painter: _painter,
                      overlays: m.overlays,
                    ),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: OverlayChromePainter(
                      painter: _painter,
                      selected: _dragging == null ? selected : null,
                    ),
                  ),
                ),
                // La corbeille, le temps d'un glissement de calque.
                if (_dragging != null)
                  Positioned(
                    left: _trashRect.left,
                    top: _trashRect.top,
                    width: _trashRect.width,
                    height: _trashRect.height,
                    child: AnimatedScale(
                      scale: _overTrash ? 1.2 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (_overTrash ? Colors.redAccent : Colors.black)
                              .withValues(alpha: 0.65),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          color: Colors.white,
                        ),
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

/// Un média posé sous le cadre par la géométrie commune (`CropGeometry.matrix`),
/// à travers la matrice de couleurs et la vignette — pour la vidéo, et pour
/// une photo le temps que son image se décode.
class _TransformedMedia extends StatelessWidget {
  const _TransformedMedia({
    required this.media,
    required this.aspect,
    required this.frame,
    required this.child,
  });

  final AlbumDraftMedia media;
  final double aspect;
  final Size frame;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final m = media;
    final matrix = CropGeometry.matrix(
      m,
      aspect,
      frameW: frame.width,
      frameH: frame.height,
    );
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: m.srcWidth.toDouble(),
          height: m.srcHeight.toDouble(),
          child: Transform(
            transform: matrix,
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(m.grade.toMatrix()),
              child: child,
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _VignettePainter(m.grade.vignette)),
          ),
        ),
      ],
    );
  }
}

/// Le même voile qu'à l'export (`Vignette.alphaAt`, huit arrêts).
class _VignettePainter extends CustomPainter {
  const _VignettePainter(this.vignette);
  final double vignette;

  @override
  void paint(Canvas canvas, Size size) {
    if (vignette <= 0) return;
    final rect = Offset.zero & size;
    const n = 8;
    final stops = <double>[0, Vignette.start];
    final colors = <Color>[const Color(0x00000000), const Color(0x00000000)];
    for (var i = 1; i <= n; i++) {
      final d = Vignette.start + (1 - Vignette.start) * i / n;
      stops.add(d);
      colors.add(Color.fromRGBO(0, 0, 0, Vignette.alphaAt(d, vignette)));
    }
    final radius =
        math.sqrt(rect.width * rect.width + rect.height * rect.height) / 2;
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.radial(rect.center, radius, colors, stops),
    );
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
