import 'package:flutter/material.dart';

import '../cards/native_camera.dart';

/// ÉTAPE 1 du chantier « rendu caméra GPU » — écran de test ISOLÉ.
///
/// Affiche l'aperçu OpenGL d'UNE caméra (voir Camera2Gl.kt). Aucun impact sur
/// le flux de capture réel. À vérifier au test : l'aperçu est-il **fluide** et
/// dans le **bon sens** (pas pivoté, pas en miroir pour l'arrière) ? Le journal
/// caméra (Réglages → Développeur) trace tout (« PREMIÈRE image rendue par le
/// GPU », nombre d'images, erreurs EGL/shader).
class GlPreviewTestScreen extends StatefulWidget {
  const GlPreviewTestScreen({super.key});

  @override
  State<GlPreviewTestScreen> createState() => _GlPreviewTestScreenState();
}

class _GlPreviewTestScreenState extends State<GlPreviewTestScreen> {
  final _camera = NativeCameraController();
  var _back = true;
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

  Future<void> _open() async {
    setState(() => _error = null);
    try {
      await _camera.openGlPreview(back: _back);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _flip() async {
    await _camera.closeGlPreview();
    if (!mounted) return;
    setState(() => _back = !_back);
    await _open();
  }

  @override
  void dispose() {
    _camera.removeListener(_onChanged);
    _camera.closeGlPreview();
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _camera.glTextureId;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Aperçu GPU — étape 1')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Aperçu GPU impossible : $_error\n\n'
                        '(Le journal caméra dit pourquoi : EGL, shader, ou '
                        'caméra.)',
                        style: const TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : id == null
                  ? const CircularProgressIndicator()
                  : AspectRatio(
                      aspectRatio: 9 / 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        // Rotation + miroir déjà appliqués par le shader :
                        // ici on ne fait que « couvrir » la texture.
                        child: NativeCameraPreview(
                          textureId: id,
                          info: _camera.previews['gl'],
                          mirror: false,
                        ),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _flip,
              icon: const Icon(Icons.cameraswitch),
              label: Text(
                _back
                    ? 'Caméra arrière → passer à l\'avant'
                    : 'Caméra avant → passer à l\'arrière',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
