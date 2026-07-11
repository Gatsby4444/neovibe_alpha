import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/card.dart';
import 'card_send_screen.dart';
import 'face_editor_screen.dart';

/// Flux de création d'une Card : recto (caméra arrière) → verso (caméra
/// avant) → choix du type → envoi/publication. Objectif : 10 s, zéro
/// post-production imposée (l'éditeur de face reste optionnel).
///
/// Mode Oneshot : un seul déclenché capture les deux faces (arrière puis
/// avant enchaînées au plus vite — la capture strictement simultanée des deux
/// caméras n'est pas permise par Android sur la plupart des appareils).
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
  var _oneshotMode = false;
  var _capturing = false;

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

  Future<void> _useCamera(CameraLensDirection direction) async {
    final camera = _cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => _cameras.first,
    );
    final previous = _controller;
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
    setState(() => _controller = controller);
    previous?.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    _capturing = true;
    try {
      if (_oneshotMode) {
        // Un seul déclenché : arrière puis avant, enchaînées au plus vite
        final backShot = await controller.takePicture();
        _front = File(backShot.path);
        setState(() => _step = 1);
        await _useCamera(CameraLensDirection.front);
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
    } finally {
      _capturing = false;
    }
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
      return _RecapStep(
        front: _front!,
        back: _back!,
        forcedType: widget.bereal
            ? CardType.bereal
            : _oneshotMode
            ? CardType.oneshot
            : null,
      );
    }

    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (controller != null && controller.value.isInitialized)
              Positioned.fill(child: CameraPreview(controller))
            else
              const Center(child: CircularProgressIndicator()),
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
            // Mode Oneshot : les deux faces en un seul déclenché
            if (!widget.bereal && _step == 0)
              Positioned(
                bottom: 120,
                left: 0,
                right: 0,
                child: Center(
                  child: FilterChip(
                    selected: _oneshotMode,
                    onSelected: (v) => setState(() => _oneshotMode = v),
                    selectedColor: CardType.oneshot.color.withValues(
                      alpha: 0.35,
                    ),
                    label: Text(
                      'Oneshot — les 2 faces d\'un coup',
                      style: TextStyle(
                        color: _oneshotMode ? Colors.white : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _capture,
                  child: Container(
                    height: 76,
                    width: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _oneshotMode
                            ? CardType.oneshot.color
                            : Colors.white,
                        width: 5,
                      ),
                    ),
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

/// Étape 3 : aperçu recto/verso (remplaçables via l'éditeur) + choix du type.
class _RecapStep extends StatefulWidget {
  const _RecapStep({required this.front, required this.back, this.forcedType});
  final File front;
  final File back;
  final CardType? forcedType;

  @override
  State<_RecapStep> createState() => _RecapStepState();
}

class _RecapStepState extends State<_RecapStep> {
  late CardType _type = widget.forcedType ?? CardType.standard;
  late File _front = widget.front;
  late File _back = widget.back;

  Future<void> _editFace(bool isFront, {required bool fromBlank}) async {
    final result = await Navigator.of(context).push<File>(
      MaterialPageRoute(
        builder: (_) => FaceEditorScreen(
          baseImage: fromBlank ? null : (isFront ? _front : _back),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        if (isFront) {
          _front = result;
        } else {
          _back = result;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = widget.forcedType != null
        ? [widget.forcedType!]
        : CardType.selectable;

    return Scaffold(
      appBar: AppBar(title: const Text('Ta Card')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _Shot(
                  label: 'Recto',
                  file: _front,
                  onAnnotate: () => _editFace(true, fromBlank: false),
                  onCreate: () => _editFace(true, fromBlank: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Shot(
                  label: 'Verso',
                  file: _back,
                  onAnnotate: () => _editFace(false, fromBlank: false),
                  onCreate: () => _editFace(false, fromBlank: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Type de Card', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<CardType>(
            groupValue: _type,
            onChanged: (v) {
              if (widget.forcedType == null && v != null) {
                setState(() => _type = v);
              }
            },
            child: Column(
              children: [
                for (final type in types)
                  RadioListTile<CardType>(
                    value: type,
                    title: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
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
                              color: type.gradient == null
                                  ? type.color
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Text(type.description),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) =>
                    CardSendScreen(front: _front, back: _back, type: _type),
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
    required this.onAnnotate,
    required this.onCreate,
  });
  final String label;
  final File file;
  final VoidCallback onAnnotate;
  final VoidCallback onCreate;

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
            // Éditeur façon Snapchat : annoter la photo, ou créer une face
            // entièrement dans l'éditeur (consigne Jay : les deux)
            IconButton(
              icon: const Icon(Icons.draw, size: 20),
              tooltip: 'Annoter',
              onPressed: onAnnotate,
            ),
            IconButton(
              icon: const Icon(Icons.palette, size: 20),
              tooltip: 'Remplacer par une création',
              onPressed: onCreate,
            ),
          ],
        ),
      ],
    );
  }
}
