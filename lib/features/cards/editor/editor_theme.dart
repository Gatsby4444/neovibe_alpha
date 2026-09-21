import 'package:flutter/material.dart';

import '../../../core/palette.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';

/// **Les couleurs de l'éditeur** — celles du thème en vigueur, pas un
/// noir imposé.
///
/// Le premier jet (v0.9.187) forçait l'éditeur en sombre « comme
/// Instagram ». Retour de Jay : *« Le thème clair affiche l'interface en
/// noir, même le thème sable, le texte est illisible […] Le thème n'est pas
/// respecté. »* La DA prime : l'éditeur, la galerie et l'écran de légende
/// reprennent la palette de l'identité (clair, sable, sombre). Seule l'image
/// reste l'image, et ce qui se pose SUR l'image (calques, boutons du
/// cadrage) reste blanc sur un voile sombre, lisible quel que soit le thème.
class EditorColors {
  const EditorColors._(this.palette, this.scheme);

  final NeoPalette palette;
  final ColorScheme scheme;

  static EditorColors of(BuildContext context) =>
      EditorColors._(context.palette, Theme.of(context).colorScheme);

  /// Le fond des écrans.
  Color get bg => palette.ground;

  /// Une surface posée sur le fond (panneaux, feuilles).
  Color get surface => palette.surface;

  /// Une surface plus marquée (cases, puces, boutons neutres).
  Color get raised => palette.field;

  Color get line => palette.line;
  Color get ink => palette.ink;
  Color get inkMuted => palette.inkMuted;
  Color get inkFaint => palette.ink.withValues(alpha: 0.42);

  /// L'accent de l'identité.
  Color get accent => palette.action;
  Color get onAccent => palette.onAction;

  /// Le fond derrière l'image, là où elle ne couvre pas : neutre et sombre
  /// dans tous les thèmes, pour ne pas teinter la photo.
  Color get canvas => const Color(0xFF101012);

  /// Ce qui se pose SUR l'image : toujours blanc, sur un voile sombre.
  Color get onImage => Colors.white;
  Color get scrim => Colors.black.withValues(alpha: 0.55);
}

/// Le bouton « Suivant » / « Publier » de l'éditeur : une pastille pleine
/// de l'accent, discrète tant qu'elle n'est pas disponible.
class EditorPrimaryButton extends StatelessWidget {
  const EditorPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: NeoSpace.sm),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          disabledBackgroundColor: c.raised,
          foregroundColor: c.onAccent,
          disabledForegroundColor: c.inkFaint,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        child: Text(label),
      ),
    );
  }
}

/// Un bouton rond posé SUR l'image (cadrage, outils de texte) : blanc sur
/// voile sombre, ou plein blanc quand il est actif.
class OnImageButton extends StatelessWidget {
  const OnImageButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.active = false,
    this.size = 40,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Colors.white : Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: size * 0.5,
              color: active ? Colors.black : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
