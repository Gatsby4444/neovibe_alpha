import 'package:flutter/material.dart';

import '../cards/native_camera.dart';

/// Chantier « rendu caméra GPU » — écran de test ISOLÉ (aucun impact sur le flux
/// de capture réel).
///
/// - **Simple** (étape 1, validée) : aperçu OpenGL d'UNE caméra, ~30 i/s
///   constant. Orientation figée : rotation 0, miroir off (la matrice de la
///   SurfaceTexture gère déjà le sens sur cet appareil — trouvé au test).
/// - **Double** (étape 2) : les DEUX caméras en GPU, arrière en grand + avant
///   en vignette. C'est la cible : double flux fluide sans le rendu logiciel.
class GlPreviewTestScreen extends StatefulWidget {
  const GlPreviewTestScreen({super.key});

  @override
  State<GlPreviewTestScreen> createState() => _GlPreviewTestScreenState();
}

class _GlPreviewTestScreenState extends State<GlPreviewTestScreen> {
  final _camera = NativeCameraController();
  var _dual = false;
  var _back = true; // mode simple : caméra affichée
  String? _error;

  @override
  void initState() {
    super.initState();
    _camera.addListener(_onChanged);
    _open();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _closeAll() async {
    await _camera.closeGlPreview();
    await _camera.closeGlDual();
  }

  Future<void> _open() async {
    setState(() => _error = null);
    try {
      if (_dual) {
        await _camera.openGlDual();
      } else {
        await _camera.openGlPreview(back: _back, rotation: 0, mirror: false);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _setMode(bool dual) async {
    if (dual == _dual) return;
    await _closeAll();
    if (!mounted) return;
    setState(() => _dual = dual);
    await _open();
  }

  Future<void> _flipCamera() async {
    await _camera.closeGlPreview();
    if (!mounted) return;
    setState(() => _back = !_back);
    await _open();
  }

  @override
  void dispose() {
    _camera.removeListener(_onChanged);
    _closeAll();
    _camera.dispose();
    super.dispose();
  }

  Widget _preview(String key, int? textureId) {
    if (textureId == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return NativeCameraPreview(
      textureId: textureId,
      info: _camera.previews[key],
      mirror: false,
    );
  }

  Widget _body() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Aperçu GPU impossible : $_error',
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_dual) {
      final back = _camera.glBackTextureId;
      final front = _camera.glFrontTextureId;
      if (back == null || front == null) {
        return const CircularProgressIndicator();
      }
      return AspectRatio(
        aspectRatio: 9 / 16,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pipW = constraints.maxWidth * 0.3;
              return Stack(
                children: [
                  Positioned.fill(child: _preview('glBack', back)),
                  Positioned(
                    top: 12,
                    right: 12,
                    width: pipW,
                    height: pipW * 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _preview('glFront', front),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    }
    final id = _camera.glTextureId;
    if (id == null) return const CircularProgressIndicator();
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _preview('gl', id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Aperçu GPU')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Simple (1 caméra)')),
                ButtonSegment(value: true, label: Text('Double (2 caméras)')),
              ],
              selected: {_dual},
              onSelectionChanged: (s) => _setMode(s.first),
            ),
          ),
          Expanded(child: Center(child: _body())),
          if (!_dual)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.tonalIcon(
                onPressed: _flipCamera,
                icon: const Icon(Icons.cameraswitch),
                label: Text(_back ? 'Caméra arrière' : 'Caméra avant'),
              ),
            ),
        ],
      ),
    );
  }
}
