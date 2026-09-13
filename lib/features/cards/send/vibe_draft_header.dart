import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/models/card.dart';
import '../../../core/typography.dart';

/// **La Vibe en petit, en haut de l'écran « À qui ? »** — le récap intégré
/// (plan §2.2, étape A5).
///
/// Avant, le récap était un écran à part : on regardait ce qu'on venait de
/// prendre, puis « Continuer », puis on choisissait à qui. Ici les faces sont
/// là, petites, et chacune garde ses trois gestes derrière un menu ⋯ :
/// **Modifier** (dessin, texte — photos non importées seulement), **Revenir à
/// l'original** (si modifiée), **Refaire** cette face en gardant l'autre
/// (consigne Jay 2026-07-26).
class VibeDraftHeader extends StatelessWidget {
  const VibeDraftHeader({
    super.key,
    required this.front,
    required this.back,
    required this.type,
    required this.frontEdited,
    required this.backEdited,
    required this.frontImported,
    required this.backImported,
    required this.frontIsVideo,
    required this.backIsVideo,
    required this.onEdit,
    required this.onRestore,
    required this.onRetake,
  });

  final File front;

  /// Nulle = face unique (verso passé).
  final File? back;
  final CardType type;
  final bool frontEdited;
  final bool backEdited;
  final bool frontImported;
  final bool backImported;
  final bool frontIsVideo;
  final bool backIsVideo;

  /// `true` = recto.
  final void Function(bool isFront) onEdit;
  final void Function(bool isFront) onRestore;
  final void Function(bool isFront) onRetake;

  static const _hauteur = 132.0;

  @override
  Widget build(BuildContext context) {
    final verso = back;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.lg,
        NeoSpace.sm,
        NeoSpace.lg,
        NeoSpace.xs,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Face(
            label: verso == null ? 'Face unique' : 'Recto',
            file: front,
            isVideo: frontIsVideo,
            edited: frontEdited,
            imported: frontImported,
            hauteur: _hauteur,
            onEdit: () => onEdit(true),
            onRestore: () => onRestore(true),
            onRetake: () => onRetake(true),
          ),
          if (verso != null) ...[
            const SizedBox(width: NeoSpace.md),
            _Face(
              label: 'Verso',
              file: verso,
              isVideo: backIsVideo,
              edited: backEdited,
              imported: backImported,
              hauteur: _hauteur,
              onEdit: () => onEdit(false),
              onRestore: () => onRestore(false),
              onRetake: () => onRetake(false),
            ),
          ],
        ],
      ),
    );
  }
}

enum _Geste { modifier, original, refaire }

class _Face extends StatelessWidget {
  const _Face({
    required this.label,
    required this.file,
    required this.isVideo,
    required this.edited,
    required this.imported,
    required this.hauteur,
    required this.onEdit,
    required this.onRestore,
    required this.onRetake,
  });

  final String label;
  final File file;
  final bool isVideo;
  final bool edited;
  final bool imported;
  final double hauteur;
  final VoidCallback onEdit;
  final VoidCallback onRestore;
  final VoidCallback onRetake;

  @override
  Widget build(BuildContext context) {
    // Une face vidéo ou importée ne se dessine pas (photos non importées
    // seulement — consigne Jay).
    final peutModifier = !isVideo && !imported;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NeoRadius.sm),
              child: SizedBox(
                height: hauteur,
                width: hauteur * 9 / 16,
                child: isVideo
                    ? VideoLoopThumb(file: file)
                    : Image.file(file, fit: BoxFit.cover),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: PopupMenuButton<_Geste>(
                tooltip: 'Modifier cette face',
                icon: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.more_horiz,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
                onSelected: (g) => switch (g) {
                  _Geste.modifier => onEdit(),
                  _Geste.original => onRestore(),
                  _Geste.refaire => onRetake(),
                },
                itemBuilder: (_) => [
                  if (peutModifier)
                    const PopupMenuItem(
                      value: _Geste.modifier,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.draw, size: 18),
                        title: Text('Modifier (dessin, texte)'),
                      ),
                    ),
                  if (edited && !isVideo)
                    const PopupMenuItem(
                      value: _Geste.original,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.restore, size: 18),
                        title: Text('Revenir à l\'original'),
                      ),
                    ),
                  const PopupMenuItem(
                    value: _Geste.refaire,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.replay, size: 18),
                      title: Text('Refaire cette face'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

/// Aperçu vidéo : lecture en boucle, muette, recadrée cover.
class VideoLoopThumb extends StatefulWidget {
  const VideoLoopThumb({super.key, required this.file});
  final File file;

  @override
  State<VideoLoopThumb> createState() => _VideoLoopThumbState();
}

class _VideoLoopThumbState extends State<VideoLoopThumb> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    widget.file,
  );

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller
        ..setLooping(true)
        ..setVolume(0)
        ..play();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: Icon(Icons.videocam, color: Colors.white38)),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: _controller.value.size.width,
        height: _controller.value.size.height,
        child: VideoPlayer(_controller),
      ),
    );
  }
}
