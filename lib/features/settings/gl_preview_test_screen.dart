import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
  var _busy = false; // une ouverture/fermeture est en cours
  var _recording = false; // enregistrement vidéo double en cours
  var _videoBusy = false; // start/stop vidéo en cours
  DateTime? _recStart;
  Timer? _recTimer;
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

  /// Sérialise les ouvertures/fermetures : sans ça, basculer les modes vite
  /// lançait DEUX ouvertures de la même caméra en parallèle → le service caméra
  /// refuse (« Error configuring streams -38 ») et l'app crashait (journal Jay,
  /// v0.9.10).
  Future<void> _guarded(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMode(bool dual) => _guarded(() async {
    if (dual == _dual) return;
    await _closeAll();
    if (!mounted) return;
    setState(() => _dual = dual);
    await _open();
  });

  Future<void> _flipCamera() => _guarded(() async {
    await _camera.closeGlPreview();
    if (!mounted) return;
    setState(() => _back = !_back);
    await _open();
  });

  Future<void> _capture() async {
    try {
      final shots = await _camera.captureGlDual();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Photo GPU — deux faces'),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: Image.file(shots.back, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: Image.file(shots.front, fit: BoxFit.cover),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Capture GPU impossible : $e')));
      }
    }
  }

  Future<void> _toggleRecord() async {
    if (_videoBusy) return;
    setState(() => _videoBusy = true);
    try {
      if (_recording) {
        _recTimer?.cancel();
        final files = await _camera.stopGlDualVideo();
        if (!mounted) return;
        setState(() {
          _recording = false;
          _recStart = null;
        });
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                _DualVideoPlayback(back: files.back, front: files.front),
          ),
        );
      } else {
        await _camera.startGlDualVideo();
        if (!mounted) return;
        setState(() {
          _recording = true;
          _recStart = DateTime.now();
        });
        // Rafraîchit le chrono affiché.
        _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _recStart = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Vidéo GPU impossible : $e')));
      }
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  @override
  void dispose() {
    _recTimer?.cancel();
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
                  if (_recording)
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.fiber_manual_record,
                              color: Colors.red,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _elapsed(),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
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

  Widget _simpleControls() => FilledButton.tonalIcon(
    onPressed: _busy ? null : _flipCamera,
    icon: const Icon(Icons.cameraswitch),
    label: Text(_back ? 'Caméra arrière' : 'Caméra avant'),
  );

  Widget _dualControls() {
    final ready =
        _camera.glBackTextureId != null && _camera.glFrontTextureId != null;
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: (!_busy && !_recording && ready) ? _capture : null,
            icon: const Icon(Icons.camera),
            label: const Text('Photo (2 faces)'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: (!_busy && !_videoBusy && ready) ? _toggleRecord : null,
            style: _recording
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            icon: Icon(_recording ? Icons.stop : Icons.videocam),
            label: Text(_recording ? 'Arrêter' : 'Vidéo (2 faces)'),
          ),
        ),
      ],
    );
  }

  String _elapsed() {
    final start = _recStart;
    if (start == null) return '';
    final s = DateTime.now().difference(start).inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
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
              onSelectionChanged: (_busy || _recording)
                  ? null
                  : (s) => _setMode(s.first),
            ),
          ),
          Expanded(child: Center(child: _body())),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _dual ? _dualControls() : _simpleControls(),
          ),
        ],
      ),
    );
  }
}

/// Lecture des DEUX vidéos GPU (recto/verso) côte à côte, en boucle. Sert à
/// vérifier au test que la vidéo double GPU sort droite, fluide, couleurs OK.
class _DualVideoPlayback extends StatefulWidget {
  const _DualVideoPlayback({required this.back, required this.front});
  final File back;
  final File front;

  @override
  State<_DualVideoPlayback> createState() => _DualVideoPlaybackState();
}

class _DualVideoPlaybackState extends State<_DualVideoPlayback> {
  late final VideoPlayerController _back;
  late final VideoPlayerController _front;
  var _ready = false;

  @override
  void initState() {
    super.initState();
    _back = VideoPlayerController.file(widget.back);
    _front = VideoPlayerController.file(widget.front);
    Future.wait([_back.initialize(), _front.initialize()]).then((_) {
      if (!mounted) return;
      _back
        ..setLooping(true)
        ..play();
      _front
        ..setLooping(true)
        ..play();
      setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _back.dispose();
    _front.dispose();
    super.dispose();
  }

  Widget _tile(String label, VideoPlayerController c) => Expanded(
    child: Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 6),
        Expanded(
          child: AspectRatio(
            aspectRatio: c.value.aspectRatio,
            child: VideoPlayer(c),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Vidéo GPU — deux faces'),
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _tile('Arrière (recto)', _back),
                  const SizedBox(width: 8),
                  _tile('Avant (verso)', _front),
                ],
              ),
            ),
    );
  }
}
