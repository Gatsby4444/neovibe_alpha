import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/card.dart';
import 'card_send_screen.dart';

/// Flux de création d'une Card : recto (caméra arrière) → verso (caméra
/// avant) → choix du type → envoi/publication. Objectif : 10 s, zéro
/// post-production (spec 4.8).
class CardCaptureScreen extends ConsumerStatefulWidget {
  const CardCaptureScreen({super.key, this.bereal = false});

  /// Mode BeReal : fenêtre de capture contrainte (spec 4.8.1).
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

  /// Fenêtre BeReal : 30 s pour boucler les deux captures.
  static const _berealWindow = Duration(seconds: 30);
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
    if (controller == null || !controller.value.isInitialized) return;
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
        forcedType: widget.bereal ? CardType.bereal : null,
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
                          color: const Color(0xFF9E9E9E),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'BeReal · $_berealRemaining s',
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
                      border: Border.all(color: Colors.white, width: 5),
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

/// Étape 3 : aperçu recto/verso + choix du type (fixé à la création — spec).
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
  int _oneshotDuration = 3;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ta Card')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _Shot(label: 'Recto', file: widget.front),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Shot(label: 'Verso', file: widget.back),
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
                for (final type in CardType.values)
                  RadioListTile<CardType>(
                    value: type,
                    enabled:
                        widget.forcedType == null || type == widget.forcedType,
                    title: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: type.color.withValues(alpha: 0.2),
                            border: Border.all(color: type.color),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            type.tag,
                            style: TextStyle(
                              color: type.color,
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
          if (_type == CardType.oneshot) ...[
            const SizedBox(height: 8),
            Text('Durée de visionnage : $_oneshotDuration s'),
            Slider(
              value: _oneshotDuration.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$_oneshotDuration s',
              onChanged: (v) => setState(() => _oneshotDuration = v.round()),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => CardSendScreen(
                  front: widget.front,
                  back: widget.back,
                  type: _type,
                  oneshotDuration: _oneshotDuration,
                ),
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
  const _Shot({required this.label, required this.file});
  final String label;
  final File file;

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
      ],
    );
  }
}
