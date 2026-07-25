import 'package:flutter/material.dart';

import '../theme.dart';

/// Briques réutilisables portant le dégradé de marque, pour les endroits où
/// Flutter n'accepte qu'une couleur unie (icônes, texte, FAB, avatars).

/// Icône peinte avec le dégradé de marque.
class GradientIcon extends StatelessWidget {
  const GradientIcon(
    this.icon, {
    super.key,
    this.size = 24,
    this.gradient = NeoGradients.brandButton,
  });

  final IconData icon;
  final double size;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      // srcIn : la couleur du dégradé remplace celle de l'icône, en gardant
      // sa forme (alpha). L'icône dessous doit être opaque — d'où le blanc.
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(bounds),
      child: Icon(icon, size: size, color: Colors.white),
    );
  }
}

/// Texte peint avec le dégradé de marque (titres, valeurs mises en avant).
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    this.style,
    this.gradient = NeoGradients.brandButton,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final Gradient gradient;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(bounds),
      child: Text(
        text,
        textAlign: textAlign,
        style: (style ?? const TextStyle()).copyWith(color: Colors.white),
      ),
    );
  }
}

/// Pastille ronde en dégradé (bouton d'action compact, badge, puce de nav).
class GradientDot extends StatelessWidget {
  const GradientDot({
    super.key,
    required this.child,
    this.size = 44,
    this.gradient = NeoGradients.brandButton,
  });

  final Widget child;
  final double size;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: gradient),
      child: child,
    );
  }
}

/// Bouton flottant en dégradé — remplace `FloatingActionButton` là où l'accent
/// de marque doit être visible (le thème ne sait pas peindre un FAB en dégradé).
class GradientFab extends StatelessWidget {
  const GradientFab({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.label,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String? tooltip;

  /// Si fourni, rend un FAB étendu (icône + texte).
  final String? label;

  @override
  Widget build(BuildContext context) {
    final extended = label != null;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white),
        if (extended) ...[
          const SizedBox(width: 10),
          Text(
            label!,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );

    return Tooltip(
      message: tooltip ?? label ?? '',
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          gradient: NeoGradients.brandButton,
          borderRadius: BorderRadius.circular(extended ? 16 : 28),
          boxShadow: [
            BoxShadow(
              color: NeoTheme.accentPink.withValues(alpha: .35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(extended ? 16 : 28),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: extended ? 20 : 16),
              child: SizedBox(width: extended ? null : 24, child: content),
            ),
          ),
        ),
      ),
    );
  }
}

/// Anneau en dégradé autour d'un avatar (registre « story »).
/// `ring` à false pour afficher l'avatar seul sans l'anneau.
class GradientRing extends StatelessWidget {
  const GradientRing({
    super.key,
    required this.child,
    this.size = 56,
    this.thickness = 2.5,
    this.ring = true,
  });

  final Widget child;
  final double size;
  final double thickness;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    if (!ring) return SizedBox(width: size, height: size, child: child);
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: NeoGradients.brand,
      ),
      padding: EdgeInsets.all(thickness),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        padding: const EdgeInsets.all(2),
        child: ClipOval(child: child),
      ),
    );
  }
}
