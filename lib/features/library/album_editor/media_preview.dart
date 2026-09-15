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

/// **L'aperçu d'un média et son cadre**, avec ses gestes.
///
/// Retour de Jay (2026-09-15) sur le premier jet : *« Le viewer de recadrage
/// n'est pas pro. Il ne permet pas de bien voir l'image, et délimiter si ce
/// qu'on voit c'est ce qui va être publié ou si c'est le cadre. »* D'où :
///
/// - **l'image entière est visible**, assombrie hors du cadre ; le cadre est
///   délimité, et **ce qui est clair est exactement ce qui sera publié** ;
/// - une **grille des tiers** apparaît pendant le geste (cadrer, zoomer,
///   redresser), comme dans tout outil de cadrage sérieux ;
/// - un bouton **Adapter / Remplir** : l'image entière avec des bandes, ou le
///   cadre plein.
///
/// - Une **photo** est peinte dans le cadre par le shader (`GradePainter`) :
///   cadrage, rotation, filtre, réglages, vignette — exactement ce que
///   l'export produira. Autour, la même image transformée par la même
///   géométrie (`CropGeometry.matrix`), assombrie.
/// - Une **vidéo** joue dans un lecteur ordinaire posé par cette géométrie, à
///   travers la matrice de couleurs et le voile de vignette. Ombres, hautes
///   lumières et netteté ne se voient pas sur l'aperçu vidéo ; elles
///   s'appliquent au rendu final.
/// - Les **calques** (textes, autocollants) sont dessinés dans le cadre par le
///   même peintre que l'export ; un texte en cours d'écriture est **tapé
///   directement sur l'image** (Jay : *« un input vide invisible, juste le
///   curseur »*), borné à la largeur du cadre.
///
/// Gestes : un doigt sur un calque le déplace (bloqué au bord du cadre,
/// jamais reformaté) ; deux doigts le zooment et le tournent. Ailleurs, un
/// doigt cadre l'image, deux la zooment. Un tap sur un calque le sélectionne
/// (un texte : l'ouvre à l'écriture) ; un calque lâché sur la corbeille est
/// retiré.
class MediaPreview extends StatefulWidget {
  const MediaPreview({
    super.key,
    required this.media,
    required this.aspect,
    required this.images,
    required this.selectedOverlayId,
    required this.editingText,
    required this.textController,
    required this.onCrop,
    required this.onOverlayChanged,
    required this.onOverlaySelected,
    required this.onOverlayTapped,
    required this.onOverlayRemoved,
    this.interactive = true,
  });

  final AlbumDraftMedia media;
  final double aspect;
  final EditorImages images;
  final String? selectedOverlayId;

  /// Le texte en cours d'écriture, tapé sur l'image ; nul sinon.
  final TextOverlay? editingText;
  final TextEditingController textController;
  final ValueChanged<CropSpec> onCrop;
  final ValueChanged<OverlayObject> onOverlayChanged;
  final ValueChanged<String?> onOverlaySelected;
  final ValueChanged<OverlayObject> onOverlayTapped;
  final ValueChanged<String> onOverlayRemoved;

  /// Faux pendant l'écriture d'un texte : ni cadrage ni déplacement.
  final bool interactive;

  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview> {
  ui.Image? _full;
  OverlayObject? _dragging;
  var _overTrash = false;
  var _cropping = false;
  double _lastScale = 1;
  double _lastRotation = 0;
  Rect _frame = Rect.zero;

  late final OverlayPainter _painter = OverlayPainter(
    images: (path) => widget.images.stickerReady(path),
  );

  /// La marge autour du cadre, pour voir l'image déborder.
  static const _margin = 12.0;

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

  Offset _inFrame(Offset local) => local - _frame.topLeft;

  void _onTapUp(TapUpDetails d) {
    if (!widget.interactive) return;
    final p = _inFrame(d.localPosition);
    final hit = _painter.hitTest(_frame.size, widget.media.overlays, p);
    if (hit == null) {
      widget.onOverlaySelected(null);
      return;
    }
    widget.onOverlaySelected(hit.id);
    widget.onOverlayTapped(hit);
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (!widget.interactive) return;
    _lastScale = 1;
    _lastRotation = 0;
    _overTrash = false;
    final hit = _painter.hitTest(
      _frame.size,
      widget.media.overlays,
      _inFrame(d.localFocalPoint),
    );
    _dragging = hit;
    _cropping = hit == null;
    if (hit != null) widget.onOverlaySelected(hit.id);
    setState(() {});
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (!widget.interactive) return;
    final dragging = _dragging;
    if (dragging != null) {
      final current = widget.media.overlays
          .where((o) => o.id == dragging.id)
          .firstOrNull;
      if (current == null) return;
      // La boîte APRÈS le zoom du geste : c'est elle qu'on bloque au bord.
      final scaled = current.moved(
        scale: (current.scale * d.scale / _lastScale).clamp(
          OverlayObject.minScale,
          OverlayObject.maxScale,
        ),
      );
      final half = _painter.halfBox(_frame.size, scaled);
      final next = current.gestured(
        frameW: _frame.width,
        frameH: _frame.height,
        halfW: half.width,
        halfH: half.height,
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
      _cropping = false;
      _overTrash = false;
    });
  }

  Rect get _trashRect => Rect.fromCenter(
    center: Offset(_frame.center.dx, _frame.bottom - 44),
    width: 96,
    height: 72,
  );

  /// Le plus grand cadre du ratio dans la zone, avec sa marge.
  static Rect _fitFrame(Size area, double aspect) {
    final w = area.width - 2 * _margin;
    final h = area.height - 2 * _margin;
    double fw, fh;
    if (w / h > aspect) {
      fh = h;
      fw = fh * aspect;
    } else {
      fw = w;
      fh = fw / aspect;
    }
    return Rect.fromCenter(
      center: Offset(area.width / 2, area.height / 2),
      width: fw,
      height: fh,
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final c = EditorColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        _frame = _fitFrame(area, widget.aspect);
        final selected = widget.selectedOverlayId == null
            ? null
            : m.overlays
                  .where((o) => o.id == widget.selectedOverlayId)
                  .firstOrNull;
        final editing = widget.editingText;
        // Les calques dessinés : tous, sauf celui qu'on est en train d'écrire
        // (il est un champ de saisie, pas un dessin, tant qu'on tape).
        final drawn = editing == null
            ? m.overlays
            : m.overlays.where((o) => o.id != editing.id).toList();
        final matrix = CropGeometry.matrix(
          m,
          widget.aspect,
          frameW: _frame.width,
          frameH: _frame.height,
        )..leftTranslateByDouble(_frame.left, _frame.top, 0, 1);
        final fitted = CropGeometry.isFitted(m, widget.aspect);

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
                ColoredBox(color: c.canvas),
                // 1. L'image entière, par la géométrie commune — ce qui
                //    déborde du cadre reste visible, assombri au point 3.
                Positioned(
                  left: 0,
                  top: 0,
                  width: m.srcWidth.toDouble(),
                  height: m.srcHeight.toDouble(),
                  child: Transform(
                    transform: matrix,
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix(m.grade.toMatrix()),
                      child: m.isVideo
                          ? _VideoPreview(media: m)
                          : Image.file(
                              m.source,
                              fit: BoxFit.fill,
                              cacheWidth: 1200,
                              gaplessPlayback: true,
                            ),
                    ),
                  ),
                ),
                // 2. Le cadre : pour une photo, le shader (exactement l'export) ;
                //    pour une vidéo, les bandes noires et le voile de vignette.
                Positioned.fromRect(
                  rect: _frame,
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (m.isVideo && fitted)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _BandsPainter(
                                matrix: matrix,
                                frame: _frame,
                                srcW: m.srcWidth.toDouble(),
                                srcH: m.srcHeight.toDouble(),
                              ),
                            ),
                          ),
                        if (!m.isVideo && _full != null)
                          CustomPaint(
                            painter: GradePainter(
                              image: _full!,
                              media: m,
                              aspect: widget.aspect,
                            ),
                          ),
                        if (m.isVideo)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _VignettePainter(m.grade.vignette),
                            ),
                          ),
                        // Les calques, par le même peintre que l'export.
                        IgnorePointer(
                          child: CustomPaint(
                            painter: OverlaysPainter(
                              painter: _painter,
                              overlays: drawn,
                            ),
                          ),
                        ),
                        if (editing == null)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: OverlayChromePainter(
                                painter: _painter,
                                selected: _dragging == null ? selected : null,
                              ),
                            ),
                          ),
                        // Le texte en cours d'écriture : un champ invisible,
                        // à sa place, à sa taille, borné à la largeur du cadre.
                        if (editing != null)
                          _InlineTextField(
                            overlay: editing,
                            frame: _frame.size,
                            controller: widget.textController,
                          ),
                      ],
                    ),
                  ),
                ),
                // 3. Hors du cadre : assombri. Ce qui est clair sera publié.
                IgnorePointer(
                  child: CustomPaint(
                    painter: _FramePainter(
                      frame: _frame,
                      scrim: c.scrim,
                      grid: _cropping,
                    ),
                  ),
                ),
                // 4. Adapter / Remplir, en bas à gauche du cadre.
                if (widget.interactive && editing == null)
                  Positioned(
                    left: _frame.left + 10,
                    top: _frame.bottom - 50,
                    child: OnImageButton(
                      icon: fitted ? Icons.fullscreen : Icons.fullscreen_exit,
                      tooltip: fitted
                          ? 'Remplir le cadre'
                          : 'Voir l\'image entière',
                      onTap: () => widget.onCrop(
                        CropGeometry.toggleFit(m, widget.aspect),
                      ),
                    ),
                  ),
                // 5. La corbeille, le temps d'un glissement de calque.
                if (_dragging != null)
                  Positioned.fromRect(
                    rect: _trashRect,
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

/// Le champ de saisie d'un texte, posé sur l'image : sans fond, sans
/// bordure, sans texte d'invite — le curseur, et la même police, la même
/// taille et la même largeur maximale que le peintre du calque. Le texte
/// grandit des deux côtés (centré) et passe à la ligne au bord du cadre.
class _InlineTextField extends StatelessWidget {
  const _InlineTextField({
    required this.overlay,
    required this.frame,
    required this.controller,
  });

  final TextOverlay overlay;
  final Size frame;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final o = overlay;
    final fontSize = TextOverlay.baseSizeRatio * frame.width * o.scale;
    final maxWidth = TextOverlay.maxWidthRatio * frame.width;
    final style = OverlayPainter.textStyle(o, fontSize);
    final dark = o.color.computeLuminance() > 0.5;
    final backdrop = switch (o.backdrop) {
      TextBackdrop.none => null,
      TextBackdrop.solid => dark ? Colors.black : Colors.white,
      TextBackdrop.translucent =>
        (dark ? Colors.black : Colors.white).withValues(alpha: 0.45),
    };
    final center = o.center(frame.width, frame.height);
    return Positioned(
      left: center.dx - maxWidth / 2,
      top: center.dy,
      width: maxWidth,
      // Le champ se centre lui-même sur `center` : remonté de la moitié de sa
      // propre hauteur, puis tourné autour de son centre — exactement comme
      // le peintre pose le calque.
      child: FractionalTranslation(
        translation: const Offset(0, -0.5),
        child: Transform.rotate(
          angle: o.rotation,
          child: Container(
            padding: backdrop == null
                ? EdgeInsets.zero
                : EdgeInsets.symmetric(
                    horizontal: fontSize * 0.18,
                    vertical: fontSize * 0.06,
                  ),
            decoration: backdrop == null
                ? null
                : BoxDecoration(
                    color: backdrop,
                    borderRadius: BorderRadius.circular(fontSize * 0.22),
                  ),
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: null,
              minLines: 1,
              textAlign: switch (o.alignment) {
                TextAlignment.left => TextAlign.left,
                TextAlignment.center => TextAlign.center,
                TextAlignment.right => TextAlign.right,
              },
              textCapitalization: TextCapitalization.sentences,
              cursorColor: o.color,
              cursorWidth: math.max(2, fontSize * 0.04),
              style: style,
              // Rien : ni fond, ni bordure, ni invite, ni compteur.
              decoration: const InputDecoration(
                isCollapsed: true,
                isDense: true,
                border: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le voile hors du cadre, le liseré du cadre, et la grille des tiers
/// pendant le geste.
class _FramePainter extends CustomPainter {
  const _FramePainter({
    required this.frame,
    required this.scrim,
    required this.grid,
  });

  final Rect frame;
  final Color scrim;
  final bool grid;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(frame)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = scrim);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: grid ? 0.9 : 0.55);
    canvas.drawRect(frame, line);
    if (!grid) return;
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.5);
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thin);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), thin);
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.frame != frame || old.grid != grid || old.scrim != scrim;
}

/// Les bandes noires d'une vidéo « adaptée » : le lecteur ne couvre pas le
/// cadre, on peint le noir que le transcodeur produira — le cadre moins le
/// quadrilatère de l'image transformée.
class _BandsPainter extends CustomPainter {
  const _BandsPainter({
    required this.matrix,
    required this.frame,
    required this.srcW,
    required this.srcH,
  });

  final Matrix4 matrix;
  final Rect frame;
  final double srcW;
  final double srcH;

  @override
  void paint(Canvas canvas, Size size) {
    // Le quadrilatère de l'image, dans le repère du cadre.
    final quad = Path()
      ..addRect(Rect.fromLTWH(0, 0, srcW, srcH))
      ..transform(matrix.storage)
      ..shift(-frame.topLeft);
    final bands = Path()
      ..addRect(Offset.zero & size)
      ..addPath(quad, Offset.zero)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(bands, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_BandsPainter old) =>
      old.matrix != matrix || old.frame != frame;
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
