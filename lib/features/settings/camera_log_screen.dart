import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../cards/native_camera.dart';

/// Journal caméra (développeur) — écrit sur le disque par la couche native
/// (CamLog.kt) ET par le Dart, dans l'ordre chronologique.
///
/// Raison d'être : le double flux peut faire planter l'app, et Jay teste sans
/// PC branché (donc sans logcat). Le journal survit au crash : il suffit de
/// rouvrir l'app, venir ici et appuyer sur **Copier** pour me coller la trace.
class CameraLogScreen extends StatefulWidget {
  const CameraLogScreen({super.key});

  @override
  State<CameraLogScreen> createState() => _CameraLogScreenState();
}

class _CameraLogScreenState extends State<CameraLogScreen> {
  String _log = '';
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final log = await NativeCameraController.readLog();
    if (!mounted) return;
    setState(() {
      _log = log.trim();
      _loading = false;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _log));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Journal copié — colle-le dans le chat')),
    );
  }

  Future<void> _clear() async {
    await NativeCameraController.clearLog();
    await NativeCameraController.log('journal effacé — nouveau test');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Journal caméra'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Effacer',
            onPressed: _clear,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _log.isEmpty ? null : _copy,
        icon: const Icon(Icons.copy_all),
        label: const Text('Copier'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Mode d\'emploi : Effacer → tester le Oneshot → revenir '
                    'ici → Copier → coller dans le chat. Le journal survit à '
                    'un crash de l\'app (le plantage lui-même y est écrit).',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: _log.isEmpty
                      ? const Center(
                          child: Text(
                            'Journal vide',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                          child: SelectableText(
                            _log,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.35,
                            ),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
