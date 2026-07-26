import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'face_background.dart';

/// Ajustement d'une image importée de la galerie avant de la poser sur une
/// card (consigne Jay 2026-07-12) : recadrage par zoom/déplacement/rotation
/// avec prévisualisation dans le cadre 9:16, deux bases « Remplir » (cover)
/// et « Adapter » (image entière, fond noir visible), rotation fine au geste
/// + bouton 90°. Pas d'outils dessin/texte sur une image importée.
/// Rend un fichier PNG 900×1600 : exactement ce que montre l'aperçu.
class GalleryImportScreen extends StatefulWidget {
  const GalleryImportScreen({
    super.key,
    required this.source,
    this.background = FaceBackground.black,
  });

  final File source;

  /// Fond visible en mode « Adapter », quand l'image ne couvre pas le 9:16.
  /// Noir historiquement ; désormais la couleur choisie sur l'écran de capture
  /// (consigne Jay 2026-07-26).
  final FaceBackground background;

  @override
  State<GalleryImportScreen> createState() => _GalleryImportScreenState();
}

class _GalleryImportScreenState extends State<GalleryImportScreen> {
  final _boundaryKey = GlobalKey();

  /// Base d'affichage : true = remplir le cadre (cover), false = adapter
  /// (contain, fond noir visible si l'image ne couvre pas le 9:16).
  var _fill = false;

  // Transformation utilisateur appliquée PAR-DESSUS la base remplir/adapter.
  var _scale = 1.0;
  var _rotation = 0.0;
  var _offset = Offset.zero;

  var _startScale = 1.0;
  var _startRotation = 0.0;
  var _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  var _exporting = false;

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startRotation = _rotation;
    _startOffset = _offset;
    _startFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      _scale = (_startScale * details.scale).clamp(0.2, 8.0);
      _rotation = _startRotation + details.rotation;
      _offset = _startOffset + (details.localFocalPoint - _startFocal);
    });
  }

  void _rotate90() => setState(
    () => _rotation =
        (_rotation / (math.pi / 2)).round() * (math.pi / 2) + math.pi / 2,
  );

  void _setFill(bool fill) => setState(() {
    _fill = fill;
    // Nouvelle base : on repart d'un cadrage propre.
    _scale = 1.0;
    _rotation = 0.0;
    _offset = Offset.zero;
  });

  /// Exporte EXACTEMENT ce que montre l'aperçu, au format unifié des cards
  /// (900×1600), via le RepaintBoundary du cadre.
  Future<void> _validate() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final boundary =
          _boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final pixelRatio = 1600 / boundary.size.height;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '${Directory.systemTemp.path}/import_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      if (mounted) Navigator.of(context).pop(file);
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export impossible : $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Ajuster l\'image'),
        actions: [
          IconButton(
            tooltip: 'Pivoter de 90°',
            icon: const Icon(Icons.rotate_90_degrees_cw),
            onPressed: _rotate90,
          ),
          IconButton(
            tooltip: 'Valider',
            icon: const Icon(Icons.check),
            onPressed: _exporting ? null : _validate,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                    ),
                    child: GestureDetector(
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      child: RepaintBoundary(
                        key: _boundaryKey,
                        child: ClipRect(
                          child: DecoratedBox(
                            decoration: widget.background.decoration,
                            child: Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..translateByDouble(
                                  _offset.dx,
                                  _offset.dy,
                                  0,
                                  1,
                                )
                                ..rotateZ(_rotation)
                                ..scaleByDouble(_scale, _scale, 1, 1),
                              child: SizedBox.expand(
                                child: Image.file(
                                  widget.source,
                                  fit: _fill ? BoxFit.cover : BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('Adapter'),
                        icon: Icon(Icons.fit_screen),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('Remplir'),
                        icon: Icon(Icons.crop),
                      ),
                    ],
                    selected: {_fill},
                    onSelectionChanged: (selection) =>
                        _setFill(selection.first),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Pince pour zoomer et pivoter, fais glisser pour déplacer.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
