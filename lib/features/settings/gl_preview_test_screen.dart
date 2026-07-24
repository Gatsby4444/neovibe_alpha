import 'package:flutter/material.dart';

import '../cards/native_camera.dart';

/// ÉTAPE 1 du chantier « rendu caméra GPU » — écran de test ISOLÉ.
///
/// Affiche l'aperçu OpenGL d'UNE caméra (voir Camera2Gl.kt). Aucun impact sur
/// le flux de capture réel.
///
/// **Orientation réglable en direct** (rotation + miroir) : après 3 essais
/// ratés à deviner le bon sens, on laisse Jay le TROUVER. Il tourne jusqu'à ce
/// que l'image soit droite, note la combinaison affichée, et Claude la fige
/// pour l'étape 2. À vérifier : fluide ? et quelle rotation/miroir rend droit ?
class GlPreviewTestScreen extends StatefulWidget {
  const GlPreviewTestScreen({super.key});

  @override
  State<GlPreviewTestScreen> createState() => _GlPreviewTestScreenState();
}

class _GlPreviewTestScreenState extends State<GlPreviewTestScreen> {
  final _camera = NativeCameraController();
  var _back = true;
  var _rotation = 90; // 0 / 90 / 180 / 270
  var _mirror = false;
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
      await _camera.openGlPreview(
        back: _back,
        rotation: _rotation,
        mirror: _mirror,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _reopen() async {
    await _camera.closeGlPreview();
    if (!mounted) return;
    await _open();
  }

  Future<void> _flipCamera() async {
    setState(() {
      _back = !_back;
      // Valeur de départ plausible : arrière sans miroir, avant en miroir.
      _mirror = !_back;
    });
    await _reopen();
  }

  Future<void> _cycleRotation() async {
    setState(() => _rotation = (_rotation + 90) % 360);
    await _reopen();
  }

  Future<void> _toggleMirror() async {
    setState(() => _mirror = !_mirror);
    await _reopen();
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
                        'Aperçu GPU impossible : $_error',
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
                        // Rotation + miroir faits dans le GPU : ici on couvre
                        // simplement la texture (rotation 0, mirror false).
                        child: NativeCameraPreview(
                          textureId: id,
                          info: _camera.previews['gl'],
                          mirror: false,
                        ),
                      ),
                    ),
            ),
          ),
          // Bandeau de réglage de l'orientation (à retirer une fois figée).
          Container(
            width: double.infinity,
            color: Colors.white10,
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Caméra : ${_back ? "arrière" : "avant"}  ·  '
                  'rotation : $_rotation°  ·  miroir : ${_mirror ? "oui" : "non"}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Trouve la combinaison où l\'image est DROITE, puis note-la.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _cycleRotation,
                      icon: const Icon(Icons.rotate_right),
                      label: Text('Tourner ($_rotation°)'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _toggleMirror,
                      icon: const Icon(Icons.flip),
                      label: Text('Miroir : ${_mirror ? "on" : "off"}'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _flipCamera,
                      icon: const Icon(Icons.cameraswitch),
                      label: Text(_back ? 'Arrière' : 'Avant'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
