import 'package:flutter/material.dart';

/// Dégradés signature de NeoVibe.
///
/// Consigne de Jay (2026-07-25) : le violet plat d'origine était terne — la
/// marque passe sur un **dégradé multicolore** (registre logo Instagram :
/// jaune → orange → rose → violet → bleu), porté par les boutons et les
/// accents de l'app.
///
/// Les couleurs des **types de Cards** (`lib/core/models/card.dart` : or du
/// One of One, rouge Hot, bleu Oneshot…) ne sont PAS concernées : elles
/// restent la signature du contenu, le dégradé est la signature de l'app.
abstract final class NeoGradients {
  /// Dégradé complet, 5 arrêts — pour les grandes surfaces : anneaux d'avatar,
  /// bandeaux, écran d'accueil, éléments décoratifs.
  static const brand = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [
      Color(0xFFFEDA75), // jaune
      Color(0xFFFA7E1E), // orange
      Color(0xFFD62976), // rose
      Color(0xFF962FBF), // violet
      Color(0xFF4F5BD5), // bleu
    ],
    stops: [0.0, 0.22, 0.52, 0.78, 1.0],
  );

  /// Version courte, 3 arrêts — pour les **petites surfaces** (boutons, pastilles).
  /// Sur quelques dizaines de pixels, les 5 arrêts virent au brouillon : on
  /// garde orange → rose → violet, la partie la plus lisible du dégradé.
  static const brandButton = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFF9773C), Color(0xFFD62976), Color(0xFF7B2FF7)],
  );

  /// Dégradé atténué — états désactivés, fonds de conteneurs.
  static const brandMuted = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x33F9773C), Color(0x33D62976), Color(0x337B2FF7)],
  );
}

/// Thème NeoVibe : sombre, caméra-first, accents en dégradé de marque.
abstract final class NeoTheme {
  /// Rose central du dégradé — sert de graine au schéma de couleurs.
  static const seed = Color(0xFFD62976);

  /// Accents unis, extraits du dégradé, pour tout ce qui ne peut pas porter
  /// un dégradé (icônes, curseurs, bordures fines).
  static const accentPink = Color(0xFFE1306C);
  static const accentOrange = Color(0xFFF9773C);
  static const accentViolet = Color(0xFF7B2FF7);

  /// Fonds — noir légèrement violacé plutôt que gris neutre.
  static const bg = Color(0xFF0B0A10);
  static const surface1 = Color(0xFF15131C);
  static const surface2 = Color(0xFF1E1B29);

  static const _radius = 14.0;

  static ThemeData dark() {
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    final scheme = base.copyWith(
      primary: accentPink,
      onPrimary: Colors.white,
      secondary: accentOrange,
      tertiary: accentViolet,
      surface: bg,
      surfaceContainerHighest: surface2,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface1,
        // L'indicateur ne peut pas porter de dégradé : c'est l'icône
        // sélectionnée qui le fait (voir `GradientIcon` dans home_shell).
        indicatorColor: accentPink.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? accentPink
                : Colors.white70,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: accentPink, width: 1.5),
        ),
      ),

      // --- Boutons -----------------------------------------------------
      // Le dégradé est injecté par `backgroundBuilder` : il s'applique donc à
      // TOUS les `FilledButton`/`OutlinedButton` de l'app sans toucher aux
      // 60+ appels existants.
      filledButtonTheme: FilledButtonThemeData(style: _filledStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedStyle()),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accentPink),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        // Les FAB portent le dégradé via `GradientFab` (widget dédié) : le
        // thème ne sert qu'aux FAB restés standards.
        backgroundColor: accentPink,
        foregroundColor: Colors.white,
      ),

      // --- Contrôles ----------------------------------------------------
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentPink : null,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentPink : null,
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentPink : Colors.white54,
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: accentPink,
        thumbColor: accentPink,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accentPink,
        linearTrackColor: surface2,
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: .08),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface2,
        selectedColor: accentPink.withValues(alpha: .25),
        side: BorderSide.none,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: surface1),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: surface1),
      listTileTheme: const ListTileThemeData(iconColor: Colors.white70),
    );
  }

  /// Bouton plein : fond transparent + dégradé peint par `backgroundBuilder`.
  static ButtonStyle _filledStyle() {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: shape,
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      disabledBackgroundColor: Colors.transparent,
      disabledForegroundColor: Colors.white38,
      elevation: 0,
      shadowColor: Colors.transparent,
    ).copyWith(
      backgroundBuilder: (context, states, child) {
        final disabled = states.contains(WidgetState.disabled);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: disabled
                ? NeoGradients.brandMuted
                : NeoGradients.brandButton,
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: child,
        );
      },
    );
  }

  /// Bouton contour : la bordure est un dégradé (fin liseré peint sous le
  /// contenu, puis masqué au centre par la couleur de fond).
  static ButtonStyle _outlinedStyle() {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: shape,
      side: BorderSide.none,
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
    ).copyWith(
      backgroundBuilder: (context, states, child) {
        final disabled = states.contains(WidgetState.disabled);
        return Container(
          decoration: BoxDecoration(
            gradient: disabled
                ? NeoGradients.brandMuted
                : NeoGradients.brandButton,
            borderRadius: BorderRadius.circular(_radius),
          ),
          padding: const EdgeInsets.all(1.5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(_radius - 1.5),
            ),
            child: child,
          ),
        );
      },
    );
  }
}
