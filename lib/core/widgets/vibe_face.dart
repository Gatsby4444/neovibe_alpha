import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/card.dart';

/// L'**apparence** d'une face de Vibe : liseré à la couleur du type (dégradé
/// pour Oneshot et BeReal, or épais pour la One of One), coins arrondis, fond
/// noir, halo coloré.
///
/// Vit dans `core/widgets` depuis le 2026-08-11, et c'est une correction.
/// `CardViewerScreen` mélangeait **deux choses** : les RÈGLES d'une Vibe
/// envoyée (livraisons, budgets de vues, durées, replay) et la PRÉSENTATION
/// d'une Vibe. En écrivant les visionneuses de stories et de publications,
/// j'ai eu raison d'écarter les premières — et tort d'abandonner la seconde
/// avec : les contenus s'affichaient en image nue, sans cadre ni couleur de
/// type. Jay l'a vu immédiatement (« les cards ne s'affichent plus comme
/// avant »).
///
/// **Une Vibe doit ressembler à une Vibe, quel que soit son contexte de
/// diffusion.** L'apparence appartient au contenu ; seules les règles
/// appartiennent au format.
class VibeFaceFrame extends StatelessWidget {
  const VibeFaceFrame({super.key, required this.type, required this.child});

  final CardType type;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final borderWidth = type == CardType.oneOfOne ? 4.0 : 2.5;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.all(borderWidth),
      decoration: BoxDecoration(
        gradient: type.gradient,
        color: type.gradient == null ? type.color : null,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: type.color.withValues(alpha: 0.35), blurRadius: 24),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: ColoredBox(color: Colors.black, child: child),
      ),
    );
  }
}

/// Face photo d'une Vibe, dans son cadre.
class VibePhotoFace extends StatelessWidget {
  const VibePhotoFace({super.key, required this.file, required this.type});

  final File file;
  final CardType type;

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: type,
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const AspectRatio(
          aspectRatio: 3 / 4,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image, color: Colors.white38, size: 40),
                SizedBox(height: 8),
                Text(
                  'Image indisponible',
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Face vidéo d'une Vibe **sans limite de lecture** : story, publication.
///
/// Elle boucle, sa barre est librement déplaçable, et elle ne se déclare
/// jamais « terminée » — il n'y a aucun budget à consommer. Le chat, lui,
/// garde sa propre face vidéo dans `CardViewerScreen` : elle doit compter les
/// visionnages, synchroniser les deux faces d'un Oneshot filmé et verrouiller
/// la barre selon le choix de l'émetteur. **Seul le cadre est commun** — et
/// c'est exactement la bonne frontière.
class VibeVideoFace extends StatefulWidget {
  const VibeVideoFace({
    super.key,
    required this.file,
    required this.type,
    required this.active,
  });

  final File file;
  final CardType type;

  /// La face est posée à l'écran : la vidéo joue avec le son. Sinon elle est
  /// en pause et muette.
  final bool active;

  @override
  State<VibeVideoFace> createState() => _VibeVideoFaceState();
}

class _VibeVideoFaceState extends State<VibeVideoFace> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    widget.file,
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTick);
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller.setLooping(true);
      _controller.setVolume(widget.active ? 1 : 0);
      if (widget.active) _controller.play();
      setState(() {});
    });
  }

  void _onTick() {
    if (mounted) setState(() {}); // rafraîchit la barre de progression
  }

  @override
  void didUpdateWidget(covariant VibeVideoFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_controller.value.isInitialized) return;
    _controller.setVolume(widget.active ? 1 : 0);
    widget.active ? _controller.play() : _controller.pause();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: widget.type,
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: !_controller.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: _controller.value.size.width,
                      height: _controller.value.size.height,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: VideoProgressIndicator(
                      _controller,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      colors: VideoProgressColors(
                        playedColor: widget.type.color,
                        backgroundColor: Colors.white24,
                        bufferedColor: Colors.white38,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
