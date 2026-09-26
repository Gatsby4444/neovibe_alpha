import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/theme.dart';

/// Une action de la roue : son icône, son nom, et ce qu'elle fait.
class FriendWheelAction {
  const FriendWheelAction({
    required this.icone,
    required this.nom,
    required this.onTap,
  });

  final IconData icone;
  final String nom;
  final VoidCallback onTap;
}

/// **La roue d'actions autour d'un ami** (Jay, 2026-09-26 : *« une roue
/// d'options autour de son profil […] via une animation au clic de sa photo
/// sur la carte, de petites icônes intuitivement dessinées »*).
///
/// Posée par-dessus la carte : un voile transparent (toucher ailleurs
/// referme), et les icônes qui jaillissent en arc AU-DESSUS de la photo,
/// l'une après l'autre. [centre] est la position de la photo à l'écran,
/// dans le repère de ce widget.
class FriendWheel extends StatelessWidget {
  const FriendWheel({
    super.key,
    required this.centre,
    required this.actions,
    required this.onClose,
  });

  final Offset centre;
  final List<FriendWheelAction> actions;
  final VoidCallback onClose;

  /// Distance des icônes au centre de la photo, en points.
  static const rayon = 78.0;

  /// Diamètre d'une icône.
  static const taille = 46.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final n = actions.length;
    return Stack(
      children: [
        // Toucher ailleurs referme.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const SizedBox.expand(),
          ),
        ),
        for (var i = 0; i < n; i++)
          TweenAnimationBuilder<double>(
            key: ValueKey(i),
            tween: Tween(begin: 0, end: 1),
            // L'une après l'autre : chacune part un peu après la précédente.
            duration: Duration(milliseconds: 260 + 60 * i),
            curve: Interval(i / (n + 2), 1, curve: Curves.easeOutBack),
            builder: (context, t, child) {
              // En arc au-dessus de la photo, de gauche à droite.
              final angle = n == 1
                  ? -math.pi / 2
                  : math.pi + (math.pi * (i + 0.5) / n);
              final pos =
                  centre + Offset(math.cos(angle), math.sin(angle)) * rayon * t;
              return Positioned(
                left: pos.dx - taille / 2,
                top: pos.dy - taille / 2,
                child: Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.scale(scale: t, child: child),
                ),
              );
            },
            child: _Bouton(action: actions[i], palette: p),
          ),
      ],
    );
  }
}

class _Bouton extends StatelessWidget {
  const _Bouton({required this.action, required this.palette});

  final FriendWheelAction action;
  final NeoPalette palette;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: action.nom,
      child: Material(
        color: palette.surface,
        shape: CircleBorder(
          side: BorderSide(color: palette.action, width: 1.5),
        ),
        elevation: 6,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: action.onTap,
          child: SizedBox(
            width: FriendWheel.taille,
            height: FriendWheel.taille,
            child: Icon(action.icone, color: palette.action, size: 22),
          ),
        ),
      ),
    );
  }
}
