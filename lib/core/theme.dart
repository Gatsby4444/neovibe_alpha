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

/// Nuances de texte et d'icône secondaires, **conscientes du thème**.
///
/// Avant le 2026-08-10, l'app écrivait `Colors.white54` / `white38` / `white24`
/// un peu partout : lisible sur fond noir, illisible sur fond clair. Ces trois
/// niveaux remplacent ces constantes partout où la couleur habille l'écran
/// (et NON là où elle se pose sur une photo ou un aperçu caméra, qui restent
/// sombres quel que soit le thème et gardent donc leur blanc).
extension NeoTextColors on BuildContext {
  /// Texte secondaire courant (ancien `white70` / `white54`).
  Color get muted =>
      Theme.of(this).colorScheme.onSurface.withValues(alpha: 0.62);

  /// Mentions discrètes, horodatages (ancien `white38`).
  Color get faint =>
      Theme.of(this).colorScheme.onSurface.withValues(alpha: 0.42);

  /// Grandes icônes d'état vide, séparateurs (ancien `white24`).
  Color get ghost =>
      Theme.of(this).colorScheme.onSurface.withValues(alpha: 0.24);
}

/// Thème NeoVibe : caméra-first, accents en dégradé de marque.
///
/// Deux déclinaisons depuis le 2026-08-10 (demande de Jay) : [dark], le défaut
/// historique, et [light]. Le dégradé de marque et les couleurs de types de
/// Cards sont IDENTIQUES dans les deux — seuls les fonds et les textes
/// changent. Les écrans caméra et la visionneuse de Cards restent noirs quel
/// que soit le thème : c'est le contenu qui doit porter la lumière.
abstract final class NeoTheme {
  /// Rose central du dégradé — sert de graine au schéma de couleurs.
  static const seed = Color(0xFFD62976);

  /// Accents unis, extraits du dégradé, pour tout ce qui ne peut pas porter
  /// un dégradé (icônes, curseurs, bordures fines).
  static const accentPink = Color(0xFFE1306C);
  static const accentOrange = Color(0xFFF9773C);
  static const accentViolet = Color(0xFF7B2FF7);

  /// Fonds sombres — noir légèrement violacé plutôt que gris neutre.
  static const bg = Color(0xFF0B0A10);
  static const surface1 = Color(0xFF15131C);
  static const surface2 = Color(0xFF1E1B29);

  /// Fonds clairs — blanc très légèrement violacé, pour rester dans la même
  /// famille chromatique que le sombre au lieu d'un gris neutre étranger.
  static const bgLight = Color(0xFFFBFAFD);
  static const surface1Light = Color(0xFFFFFFFF);
  static const surface2Light = Color(0xFFEFEDF4);

  static const _radius = 14.0;

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final background = isDark ? bg : bgLight;
    final container = isDark ? surface1 : surface1Light;
    final field = isDark ? surface2 : surface2Light;
    final onBackground = isDark ? Colors.white : const Color(0xFF14121A);
    final muted = isDark ? Colors.white70 : const Color(0xFF5B5766);

    final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final scheme = base.copyWith(
      primary: accentPink,
      onPrimary: Colors.white,
      secondary: accentOrange,
      tertiary: accentViolet,
      surface: background,
      onSurface: onBackground,
      surfaceContainerHighest: field,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: onBackground,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: container,
        // L'indicateur ne peut pas porter de dégradé : c'est l'icône
        // sélectionnée qui le fait (voir `GradientIcon` dans home_shell).
        indicatorColor: accentPink.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected) ? accentPink : muted,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
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
          (s) => s.contains(WidgetState.selected) ? accentPink : muted,
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: accentPink,
        thumbColor: accentPink,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accentPink,
        linearTrackColor: field,
      ),
      dividerTheme: DividerThemeData(
        color: onBackground.withValues(alpha: isDark ? .08 : .12),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: field,
        selectedColor: accentPink.withValues(alpha: .25),
        side: BorderSide.none,
      ),
      dialogTheme: DialogThemeData(backgroundColor: container),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: container),
      listTileTheme: ListTileThemeData(iconColor: muted),
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
