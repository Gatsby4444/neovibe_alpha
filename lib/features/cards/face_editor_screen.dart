import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Éditeur de face façon Snapchat (consigne Jay) : dessin au doigt, textes
/// déplaçables, sur photo ([baseImage]) ou sur fond de couleur (création
/// vierge, [baseImage] null). Rend un PNG qui remplace la face.
class FaceEditorScreen extends StatefulWidget {
  const FaceEditorScreen({super.key, this.baseImage});

  final File? baseImage;

  @override
  State<FaceEditorScreen> createState() => _FaceEditorScreenState();
}

class _Stroke {
  _Stroke(this.color, this.width);
  final Color color;
  final double width;
  final List<Offset> points = [];
}

class _TextItem {
  _TextItem(this.text, this.color, this.offset);
  String text;
  Color color;
  Offset offset;
}

const _palette = [
  Colors.white,
  Colors.black,
  Color(0xFFC8102E), // rouge Torino
  Color(0xFFFF7A1A),
  Color(0xFFFFD60A),
  Color(0xFF7ED957),
  Color(0xFF40E0D0),
  Color(0xFF2979FF),
  Color(0xFFE040FB),
];

const _backgrounds = [
  Color(0xFF0E0E12),
  Colors.white,
  Color(0xFF1B5E20),
  Color(0xFF0D47A1),
  Color(0xFF4A148C),
  Color(0xFFB71C1C),
  Color(0xFFF57F17),
];

class _FaceEditorScreenState extends State<FaceEditorScreen> {
  final _canvasKey = GlobalKey();
  final _strokes = <_Stroke>[];
  final _texts = <_TextItem>[];
  var _color = Colors.white;
  var _strokeWidth = 5.0;
  var _backgroundIndex = 0;
  var _drawing = true; // true = pinceau, false = déplacement des textes
  var _exporting = false;

  Future<void> _addText() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Texte'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) {
      setState(() {
        _texts.add(_TextItem(text, _color, const Offset(60, 120)));
        _drawing = false;
      });
    }
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final boundary =
          _canvasKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '${Directory.systemTemp.path}/face_${DateTime.now().millisecondsSinceEpoch}.png',
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
        title: Text(widget.baseImage == null ? 'Création' : 'Annoter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Annuler le dernier trait',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() => _strokes.removeLast()),
          ),
          IconButton(
            icon: _exporting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            tooltip: 'Valider',
            onPressed: _exporting ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: RepaintBoundary(
                  key: _canvasKey,
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.baseImage != null)
                          Image.file(widget.baseImage!, fit: BoxFit.cover)
                        else
                          ColoredBox(color: _backgrounds[_backgroundIndex]),
                        // Dessin au doigt
                        GestureDetector(
                          onPanStart: _drawing
                              ? (d) => setState(() {
                                  _strokes.add(
                                    _Stroke(_color, _strokeWidth)
                                      ..points.add(d.localPosition),
                                  );
                                })
                              : null,
                          onPanUpdate: _drawing
                              ? (d) => setState(
                                  () =>
                                      _strokes.last.points.add(d.localPosition),
                                )
                              : null,
                          child: CustomPaint(
                            painter: _StrokePainter(_strokes),
                            child: const SizedBox.expand(),
                          ),
                        ),
                        // Textes déplaçables (mode déplacement)
                        for (final item in _texts)
                          Positioned(
                            left: item.offset.dx,
                            top: item.offset.dy,
                            child: GestureDetector(
                              onPanUpdate: (d) =>
                                  setState(() => item.offset += d.delta),
                              onLongPress: () =>
                                  setState(() => _texts.remove(item)),
                              child: Text(
                                item.text,
                                style: TextStyle(
                                  color: item.color,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                  shadows: const [
                                    Shadow(blurRadius: 6, color: Colors.black),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Palette de couleurs (pinceau + nouveaux textes)
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final color in _palette)
                          GestureDetector(
                            onTap: () => setState(() => _color = color),
                            child: Container(
                              width: 32,
                              height: 32,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _color == color
                                      ? Colors.white
                                      : Colors.white24,
                                  width: _color == color ? 3 : 1,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.brush,
                          color: _drawing ? _color : Colors.white38,
                        ),
                        tooltip: 'Pinceau',
                        onPressed: () => setState(() => _drawing = true),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.open_with,
                          color: _drawing ? Colors.white38 : Colors.white,
                        ),
                        tooltip: 'Déplacer les textes',
                        onPressed: () => setState(() => _drawing = false),
                      ),
                      IconButton(
                        icon: const Icon(Icons.text_fields),
                        tooltip: 'Ajouter un texte (appui long = supprimer)',
                        onPressed: _addText,
                      ),
                      if (widget.baseImage == null)
                        IconButton(
                          icon: const Icon(Icons.format_color_fill),
                          tooltip: 'Changer le fond',
                          onPressed: () => setState(
                            () => _backgroundIndex =
                                (_backgroundIndex + 1) % _backgrounds.length,
                          ),
                        ),
                      Expanded(
                        child: Slider(
                          value: _strokeWidth,
                          min: 2,
                          max: 24,
                          onChanged: (v) => setState(() => _strokeWidth = v),
                        ),
                      ),
                    ],
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

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes);
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < stroke.points.length - 1; i++) {
        canvas.drawLine(stroke.points[i], stroke.points[i + 1], paint);
      }
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first,
          stroke.width / 2,
          Paint()..color = stroke.color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_StrokePainter oldDelegate) => true;
}
