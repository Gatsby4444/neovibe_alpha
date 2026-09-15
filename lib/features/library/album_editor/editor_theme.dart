import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/typography.dart';

/// **L'habillage de l'éditeur d'album** — sombre, quel que soit le thème de
/// l'app, comme la caméra et les visionneuses : on regarde des images, le
/// cadre ne doit pas les teinter. Épuré : trois gris, du blanc, et l'accent de
/// l'identité en vigueur pour ce qui est actif.
abstract final class EditorColors {
  static const bg = Color(0xFF000000);
  static const surface = Color(0xFF141416);
  static const raised = Color(0xFF1F1F22);
  static const line = Color(0xFF2C2C30);
  static const ink = Color(0xFFFFFFFF);
  static const inkMuted = Color(0x99FFFFFF);
  static const inkFaint = Color(0x5CFFFFFF);

  /// L'accent lisible sur du noir (la palette de NUIT de l'identité).
  static Color accent(BuildContext context) => context.darkPalette.action;
}

/// Le thème Material posé sur les écrans de l'éditeur : fonds sombres,
/// textes blancs, l'accent de l'identité — le reste hérite de l'app.
ThemeData editorTheme(BuildContext context) {
  final base = Theme.of(context);
  final accent = EditorColors.accent(context);
  final scheme = ColorScheme.dark(
    primary: accent,
    onPrimary: Colors.white,
    surface: EditorColors.surface,
    onSurface: EditorColors.ink,
    surfaceContainerHighest: EditorColors.raised,
    outline: EditorColors.line,
  );
  return base.copyWith(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: EditorColors.bg,
    canvasColor: EditorColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: EditorColors.bg,
      foregroundColor: EditorColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: NeoType.display,
        fontWeight: FontWeight.w600,
        fontSize: 20,
        color: EditorColors.ink,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: EditorColors.surface,
      dragHandleColor: EditorColors.inkFaint,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: EditorColors.raised),
    textTheme: base.textTheme.apply(
      bodyColor: EditorColors.ink,
      displayColor: EditorColors.ink,
    ),
    iconTheme: const IconThemeData(color: EditorColors.ink),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: EditorColors.line,
      overlayColor: accent.withValues(alpha: 0.15),
      trackHeight: 3,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: EditorColors.ink,
        minimumSize: const Size(0, 44),
      ),
    ),
    dividerColor: EditorColors.line,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: EditorColors.raised,
      contentTextStyle: const TextStyle(color: EditorColors.ink),
      actionTextColor: accent,
    ),
  );
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
    final accent = EditorColors.accent(context);
    return Padding(
      padding: const EdgeInsets.only(right: NeoSpace.sm),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          disabledBackgroundColor: EditorColors.raised,
          foregroundColor: Colors.white,
          disabledForegroundColor: EditorColors.inkFaint,
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
