import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/card.dart';
import 'card_send_screen.dart';
import 'face_editor_screen.dart';

/// Flux de création d'une Card.
/// Le TYPE se choisit AVANT la première photo, dans un sélecteur horizontal
/// au-dessus du déclencheur (consigne Jay) — le Oneshot est donc un mode de
/// prise (les deux faces en un déclenché), pas un choix a posteriori.
/// Chaque face peut aussi être un « tableau » (fond noir à dessiner) au lieu
/// d'une photo.
class CardCaptureScreen extends ConsumerStatefulWidget {
  const CardCaptureScreen({super.key, this.bereal = false});

  /// Mode BeReal : fenêtre de capture contrainte de 5 minutes après la
  /// notification (le déclenchement manuel a été retiré du menu).
  final bool bereal;

  @override
  ConsumerState<CardCaptureScreen> createState() => _CardCaptureScreenState();
}

class _CardCaptureScreenState extends ConsumerState<CardCaptureScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  File? _front; // recto = caméra arrière (ce que je vois)
  File? _back; // verso = caméra avant (ma réaction)
  var _step = 0; // 0 = recto, 1 = verso, 2 = récap
  var _error = '';
  var _busy = false; // capture ou bascule caméra en cours
  var _switching = false;
  late CardType _type = widget.bereal ? CardType.bereal : CardType.standard;

  /// Fenêtre BeReal : 5 minutes pour boucler les deux captures (consigne Jay).
  static const _berealWindow = Duration(minutes: 5);
  Timer? _berealTimer;
  int _berealRemaining = _berealWindow.inSeconds;

  @override
  void initState() {
    super.initState();
    _init();
    if (widget.bereal) {
      _berealTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _berealRemaining--);
        if (_berealRemaining <= 0) {
          _berealTimer?.cancel();
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fenêtre BeReal écoulée — l\'instant est passé.'),
            ),
          );
        }
      });
    }
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _error = 'Permission caméra refusée');
      return;
    }
    try {
      _cameras = await availableCameras();
      await _useCamera(CameraLensDirection.back);
    } catch (e) {
      setState(() => _error = 'Caméra indisponible : $e');
    }
  }

  /// Bascule de caméra : on libère TOUJOURS l'ancien contrôleur avant d'en
  /// ouvrir un nouveau — deux contrôleurs ouverts en même temps provoquent
  /// l'écran noir sur la caméra frontale (bug remonté par Jay).
  Future<void> _useCamera(CameraLensDirection direction) async {
    setState(() => _switching = true);
    final previous = _controller;
    _controller = null;
    if (mounted) setState(() {});
    await previous?.dispose();

    final camera = _cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => _cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _switching = false;
    });
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      if (_type == CardType.oneshot && _step == 0) {
        // Oneshot : les deux faces en un seul déclenché
        final backShot = await controller.takePicture();
        _front = File(backShot.path);
        await _useCamera(CameraLensDirection.front);
        // Courte stabilisation avant le second cliché
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final frontShot = await _controller!.takePicture();
        _back = File(frontShot.path);
        _berealTimer?.cancel();
        setState(() => _step = 2);
        return;
      }
      final shot = await controller.takePicture();
      if (_step == 0) {
        _front = File(shot.path);
        setState(() => _step = 1);
        await _useCamera(CameraLensDirection.front);
      } else {
        _back = File(shot.path);
        _berealTimer?.cancel();
        setState(() => _step = 2);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Capture impossible : $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// « Face tableau » : saute la photo de la face courante et pose un fond
  /// noir, à dessiner/annoter au récap (consigne Jay).
  Future<void> _useBlackboard() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _generateBlackboard();
      if (_step == 0) {
        _front = file;
        setState(() => _step = 1);
        await _useCamera(CameraLensDirection.front);
      } else {
        _back = file;
        _berealTimer?.cancel();
        setState(() => _step = 2);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<File> _generateBlackboard() async {
    const width = 900.0, height = 1200.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/board_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return file;
  }

  @override
  void dispose() {
    _berealTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(_error)),
      );
    }
    if (_step == 2) {
      return _RecapStep(front: _front!, back: _back!, type: _type);
    }

    final controller = _controller;
    final shutterColor = _type == CardType.standard
        ? Colors.white
        : _type.color;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (controller != null && controller.value.isInitialized)
              Positioned.fill(child: CameraPreview(controller))
            else
              const Center(child: CircularProgressIndicator()),
            if (_busy && _type == CardType.oneshot)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Oneshot — les deux faces…'),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _step == 0 ? 'Recto — ce que tu vois' : 'Verso — toi',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  if (widget.bereal)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          gradient: CardType.bereal.gradient,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'BeReal · ${_berealRemaining ~/ 60}:${(_berealRemaining % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Sélecteur de type : AVANT la première photo (consigne Jay)
            if (!widget.bereal && _step == 0)
              Positioned(
                bottom: 132,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    children: [
                      for (final type in CardType.selectable)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            selected: _type == type,
                            onSelected: (_) => setState(() => _type = type),
                            selectedColor: type.color.withValues(alpha: 0.4),
                            backgroundColor: Colors.black54,
                            label: Text(
                              type.tag,
                              style: TextStyle(
                                color: _type == type
                                    ? Colors.white
                                    : type.color,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            // Face tableau : fond noir au lieu d'une photo
            Positioned(
              bottom: 42,
              right: 28,
              child: IconButton.filledTonal(
                tooltip: 'Face tableau (fond noir à dessiner)',
                icon: const Icon(Icons.gesture),
                onPressed: _busy ? null : _useBlackboard,
              ),
            ),
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _switching ? null : _capture,
                  child: Container(
                    height: 76,
                    width: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: shutterColor, width: 5),
                      color: _type == CardType.oneshot
                          ? shutterColor.withValues(alpha: 0.25)
                          : null,
                    ),
                    child: _type == CardType.oneshot
                        ? const Icon(Icons.flip_camera_android)
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Récap : aperçu recto/verso, éditeur par face, type déjà fixé (badge).
class _RecapStep extends StatefulWidget {
  const _RecapStep({
    required this.front,
    required this.back,
    required this.type,
  });
  final File front;
  final File back;
  final CardType type;

  @override
  State<_RecapStep> createState() => _RecapStepState();
}

class _RecapStepState extends State<_RecapStep> {
  late File _front = widget.front;
  late File _back = widget.back;

  /// Originaux conservés pour « revenir à l'image initiale » (consigne Jay).
  late final File _originalFront = widget.front;
  late final File _originalBack = widget.back;

  Future<void> _editFace(bool isFront) async {
    final current = isFront ? _front : _back;
    final result = await Navigator.of(context).push<File>(
      MaterialPageRoute(builder: (_) => FaceEditorScreen(baseImage: current)),
    );
    if (result != null) {
      setState(() => isFront ? _front = result : _back = result);
    }
  }

  void _restoreFace(bool isFront) {
    setState(() => isFront ? _front = _originalFront : _back = _originalBack);
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Ta Card '),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                gradient: type.gradient,
                color: type.gradient == null
                    ? type.color.withValues(alpha: 0.2)
                    : null,
                border: type.gradient == null
                    ? Border.all(color: type.color)
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                type.tag,
                style: TextStyle(
                  color: type.gradient == null ? type.color : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _Shot(
                  label: 'Recto',
                  file: _front,
                  edited: _front != _originalFront,
                  onEdit: () => _editFace(true),
                  onRestore: () => _restoreFace(true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Shot(
                  label: 'Verso',
                  file: _back,
                  edited: _back != _originalBack,
                  onEdit: () => _editFace(false),
                  onRestore: () => _restoreFace(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            type.description,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white54),
          ),
          const SizedBox(height: 16),
          FilledButton(
            // push (pas pushReplacement) : le retour depuis l'écran d'envoi
            // ramène ici, dans la section Card (consigne Jay)
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    CardSendScreen(front: _front, back: _back, type: type),
              ),
            ),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
  }
}

class _Shot extends StatelessWidget {
  const _Shot({
    required this.label,
    required this.file,
    required this.edited,
    required this.onEdit,
    required this.onRestore,
  });
  final String label;
  final File file;
  final bool edited;
  final VoidCallback onEdit;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(file, height: 220, fit: BoxFit.cover),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.draw, size: 20),
              tooltip: 'Modifier (dessin, texte)',
              onPressed: onEdit,
            ),
            if (edited)
              IconButton(
                icon: const Icon(Icons.restore, size: 20),
                tooltip: 'Revenir à l\'image initiale',
                onPressed: onRestore,
              ),
          ],
        ),
      ],
    );
  }
}
