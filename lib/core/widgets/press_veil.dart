import 'package:flutter/material.dart';

import '../motion.dart';

/// **Un voile au toucher.**
///
/// Jay, 2026-09-17 : *« il faut rajouter un petit effet qui montre quand on
/// clique dessus »* — sur la photo et le pseudo d'un auteur.
///
/// ⚠️ Un `InkWell` **était déjà là** et ne se voyait pas : son onde se peint
/// sur le `Material` qui est **derrière** les enfants. Un avatar et un pseudo
/// sont opaques ; ils la cachaient entièrement. Un retour d'appui invisible
/// n'est pas un retour d'appui — d'où un voile posé **par-dessus**, qui ne
/// dépend de rien.
///
/// Le voile prend la teinte de l'encre du thème : sombre sur fond clair
/// (le fil), et [clair] pour ce qui se pose sur une image (le plein écran).
class PressVeil extends StatefulWidget {
  const PressVeil({
    super.key,
    required this.child,
    required this.onTap,
    this.radius = 10,
    this.clair = false,
  });

  final Widget child;

  /// Nul = rien à toucher : pas de voile non plus (on ne promet pas un geste
  /// qui n'existe pas).
  final VoidCallback? onTap;

  final double radius;

  /// Voile blanc, pour ce qui est posé sur une image sombre.
  final bool clair;

  @override
  State<PressVeil> createState() => _PressVeilState();
}

class _PressVeilState extends State<PressVeil> {
  var _appuye = false;

  void _set(bool v) {
    if (widget.onTap == null || v == _appuye) return;
    setState(() => _appuye = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      // Un appui long compte aussi : le doigt s'attarde, le voile reste.
      onLongPressStart: (_) => _set(true),
      onLongPressEnd: (_) => _set(false),
      onLongPressCancel: () => _set(false),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _appuye ? 1 : 0,
                duration: NeoMotion.fast,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    color: widget.clair
                        ? Colors.white.withValues(alpha: 0.18)
                        : Colors.black.withValues(alpha: 0.10),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
