import 'package:flutter/material.dart';

import 'sealed_video_controller.dart';

/// L'image du lecteur natif.
///
/// Le décodage et le déchiffrement se passent entièrement côté natif : ce
/// widget ne fait qu'afficher la texture que le lecteur alimente.
class SealedVideoView extends StatelessWidget {
  const SealedVideoView(this.controller, {super.key});

  final SealedVideoController controller;

  @override
  Widget build(BuildContext context) {
    final id = controller.textureId;
    if (id == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final texture = Texture(textureId: id);
    final rotation = controller.value.rotationCorrection;
    // Certaines textures redressent l'image elles-mêmes, d'autres non — le
    // natif tranche et nous le dit. Redresser ici « au cas où » remettrait la
    // vidéo de travers sur la moitié des appareils.
    return rotation == 0
        ? texture
        : RotatedBox(quarterTurns: rotation ~/ 90, child: texture);
  }
}

/// Barre de progression du lecteur natif, déplaçable ou non.
///
/// `VideoProgressIndicator` est lié à `VideoPlayerController` et ne peut pas
/// être réutilisé — c'est la contrepartie assumée du lecteur natif.
class SealedVideoProgressBar extends StatelessWidget {
  const SealedVideoProgressBar({
    super.key,
    required this.controller,
    required this.allowScrubbing,
    required this.playedColor,
    this.backgroundColor = Colors.white24,
    this.bufferedColor = Colors.white38,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
  });

  final SealedVideoController controller;

  /// Faux quand l'émetteur a verrouillé le déplacement : la barre informe,
  /// elle ne commande pas.
  final bool allowScrubbing;

  final Color playedColor;
  final Color backgroundColor;
  final Color bufferedColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final bar = ValueListenableBuilder<SealedVideoValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds;
        double fraction(Duration d) =>
            total <= 0 ? 0 : (d.inMilliseconds / total).clamp(0.0, 1.0);
        return Padding(
          padding: padding,
          child: SizedBox(
            height: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(decoration: BoxDecoration(color: backgroundColor)),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction(value.buffered),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: bufferedColor),
                  ),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction(value.position),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: playedColor),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!allowScrubbing) return bar;
    return _Scrubbable(controller: controller, child: bar);
  }
}

class _Scrubbable extends StatelessWidget {
  const _Scrubbable({required this.controller, required this.child});

  final SealedVideoController controller;
  final Widget child;

  void _seekTo(BuildContext context, Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    final duration = controller.value.duration;
    if (box == null || duration == Duration.zero) return;
    final ratio = (box.globalToLocal(globalPosition).dx / box.size.width).clamp(
      0.0,
      1.0,
    );
    controller.seekTo(duration * ratio);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // La zone tactile déborde volontairement des 4 px de la barre : sans ça,
      // il faudrait viser au pixel près.
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _seekTo(context, details.globalPosition),
      onHorizontalDragStart: (details) =>
          _seekTo(context, details.globalPosition),
      onHorizontalDragUpdate: (details) =>
          _seekTo(context, details.globalPosition),
      child: child,
    );
  }
}
