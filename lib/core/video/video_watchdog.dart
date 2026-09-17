import 'dart:async';

import 'package:flutter/material.dart';

import 'sealed_video_controller.dart';

/// **Le veilleur de l'image** : il surveille une vidéo qui **joue sans qu'on
/// la voie**, et le dit.
///
/// ### Pourquoi il existe
///
/// Jay, 2026-09-17 puis 2026-09-18 : *« ça s'affiche en noir, il n'y a que le
/// son »*. Deux passes de réparation n'ont pas suffi, et la raison de fond est
/// toujours la même : **rien ne distingue un fond noir d'une image qui
/// n'arrive pas**. Le lecteur natif envoie pourtant `onRenderedFirstFrame` —
/// personne ne le lisait ailleurs que dans la mesure d'ouverture.
///
/// Ici : si la vidéo est prête, qu'elle joue, et qu'**aucune image n'a été
/// rendue** après [patience], on arrête de faire semblant. Le veilleur ne
/// répare rien : il transforme un écran noir muet en une phrase qui nomme
/// l'endroit — c'est ce qui manquait pour trancher entre un fichier sans
/// image, un décodeur refusé et une surface perdue.
///
/// ⚠️ Il ne se déclenche **jamais** sur une vidéo qui n'a pas commencé à
/// jouer : une vidéo en pause, en attente ou hors écran n'a aucune raison
/// d'avoir rendu une image.
class VideoWatchdog extends StatefulWidget {
  const VideoWatchdog({
    super.key,
    required this.controller,
    required this.child,
    this.patience = const Duration(milliseconds: 2500),
  });

  final SealedVideoController controller;
  final Widget child;
  final Duration patience;

  @override
  State<VideoWatchdog> createState() => _VideoWatchdogState();
}

class _VideoWatchdogState extends State<VideoWatchdog> {
  Timer? _minuteur;
  var _muette = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_regarde);
    _regarde();
  }

  void _regarde() {
    final v = widget.controller.value;
    if (v.hasFirstFrame || v.error != null) {
      _minuteur?.cancel();
      _minuteur = null;
      if (_muette && mounted) setState(() => _muette = false);
      return;
    }
    // Le compte à rebours ne part qu'une fois la lecture VRAIMENT lancée.
    if (v.isInitialized && v.isPlaying && _minuteur == null) {
      _minuteur = Timer(widget.patience, () {
        if (!mounted) return;
        final w = widget.controller.value;
        if (!w.hasFirstFrame && w.error == null) {
          setState(() => _muette = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    widget.controller.removeListener(_regarde);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_muette) return widget.child;
    final v = widget.controller.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        ColoredBox(
          color: Colors.black.withValues(alpha: 0.86),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.visibility_off_outlined,
                    color: Colors.white54,
                    size: 38,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Le son joue, mais aucune image n\'arrive.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Format annoncé : '
                    '${v.size.width.toInt()}×${v.size.height.toInt()}'
                    '${v.rotationCorrection == 0 ? '' : ' · ${v.rotationCorrection}°'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
