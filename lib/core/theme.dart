import 'package:flutter/material.dart';

import 'motion.dart';

/// Dégradés signature de NeoVibe.
///
/// Consigne de Jay (2026-07-25) : le violet plat d'origine était terne — la
/// marque passe sur un **dégradé multicolore** (registre logo Instagram :
/// jaune → orange → rose → violet → bleu), porté par les boutons et les
/// accents de l'app.
///
/// Les couleurs des **types de Cards** (`lib/core/models/card.dart` : or du
/// One of One, bleu Oneshot…) ne sont PAS concernées : elles restent la
/// signature du contenu, le dégradé est la signature de l'app.
///
/// ⚠️ La refonte du 2026-08-14 a neutralisé les **fonds**, pas les boutons.
/// Consigne de Jay : « en conservant les boutons colorés déjà présents ». Ce
/// bloc est donc inchangé — c'est la seule couleur qui reste dans l'habillage.
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

/// Échelle de gris **strictement neutre** — `R == G == B` sur chaque valeur.
///
/// Consigne de Jay, 2026-08-14 : « on refait un thème clair et un thème sombre
/// propre, au niveau des couleurs surtout : du noir, du blanc et du gris […]
/// tu me retires ton violet terne. On veut quelque chose de tranché et épuré. »
///
/// Ce que ça remplace : les fonds étaient des gris **tirés vers le violet**
/// (`#0B0A10`, `#15131C`, `#1E1B29` en sombre ; `#FBFAFD`, `#EFEDF4` en clair).
/// L'intention d'alors était de rester dans la famille chromatique du dégradé ;
/// le résultat lu à l'écran était un violet sale. Tout est repassé en neutre.
///
/// **La contrainte à ne pas perdre** : `R == G == B`. Une seule valeur qui
/// dérive et la teinte revient par la bande, sans qu'aucun test ne la voie.
/// Toute couleur d'habillage se prend ici — ne pas réécrire d'hexadécimal dans
/// un écran (c'est ce qui avait dispersé le violet dans sept fichiers).
abstract final class NeoNeutrals {
  // --- Sombre ---------------------------------------------------------
  /// Fond d'écran. Noir pur : « tranché », et gratuit en autonomie sur OLED.
  static const black = Color(0xFF000000);

  /// Surfaces posées sur le fond : cartes, feuilles modales, barre de nav.
  static const gray900 = Color(0xFF121212);

  /// Champs de saisie, puces, pistes de curseur.
  static const gray800 = Color(0xFF1F1F1F);

  /// Séparateurs et bordures décoratives sur fond sombre.
  static const gray700 = Color(0xFF2E2E2E);

  /// Texte et icônes secondaires sur fond sombre (10,9:1 sur noir).
  static const gray400 = Color(0xFFB0B0B0);

  // --- Clair ----------------------------------------------------------
  /// Fond d'écran. Blanc pur.
  static const white = Color(0xFFFFFFFF);

  /// Surfaces posées sur le fond : cartes, feuilles modales, barre de nav.
  static const gray50 = Color(0xFFF5F5F5);

  /// Champs de saisie, puces, pistes de curseur.
  static const gray100 = Color(0xFFEBEBEB);

  /// Séparateurs et bordures décoratives sur fond clair.
  static const gray200 = Color(0xFFD6D6D6);

  /// Texte et icônes secondaires sur fond clair (7,0:1 sur blanc).
  static const gray600 = Color(0xFF5C5C5C);

  // --- Bordures des éléments interactifs ------------------------------
  //
  // Séparées des séparateurs décoratifs, et volontairement plus soutenues.
  //
  // Pourquoi : un champ rempli ne se distingue quasiment pas de la page
  // (`#1F1F1F` sur noir = 1,26:1 ; `#F5F5F5` sur blanc = 1,19:1). Le remplissage
  // seul ne peut donc PAS porter la limite du champ — c'est précisément le
  // « noir sur noir » signalé par Jay. La bordure la porte, et elle est
  // dimensionnée pour passer le seuil WCAG 1.4.11 des composants non textuels
  // (3:1) : `#6B6B6B` donne 4,2:1 sur noir, `#8A8A8A` donne 3,4:1 sur blanc.
  //
  // Énoncé positivement : **un champ a toujours un bord visible**, quel que
  // soit son remplissage. On ne dépend plus de l'écart entre deux gris.
  static const outlineDark = Color(0xFF6B6B6B);
  static const outlineLight = Color(0xFF8A8A8A);
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

/// Thème NeoVibe : caméra-first, fonds neutres, accents en dégradé de marque.
///
/// Deux déclinaisons depuis le 2026-08-10 (demande de Jay) : [dark], le défaut
/// historique, et [light]. Le dégradé de marque et les couleurs de types de
/// Cards sont IDENTIQUES dans les deux — seuls les fonds et les textes
/// changent. Les écrans caméra et la visionneuse de Cards restent noirs quel
/// que soit le thème : c'est le contenu qui doit porter la lumière.
///
/// ## Répartition des rôles, depuis le 2026-08-14
///
/// - **Le noir, le blanc et le gris portent l'écran** — fonds, surfaces,
///   champs, textes, bordures. Tout vient de [NeoNeutrals].
/// - **La couleur ne signale plus qu'une chose : ce qui est actif.** Bouton
///   d'action (dégradé), champ au focus, interrupteur enclenché, onglet
///   courant, curseur (rose). Choix de Jay le 2026-08-14, contre l'option
///   « tout en neutre ».
abstract final class NeoTheme {
  /// Rose central du dégradé — sert de graine au schéma de couleurs.
  static const seed = Color(0xFFD62976);

  /// Accents unis, extraits du dégradé, pour tout ce qui ne peut pas porter
  /// un dégradé (icônes, curseurs, bordures fines).
  static const accentPink = Color(0xFFE1306C);
  static const accentOrange = Color(0xFFF9773C);
  static const accentViolet = Color(0xFF7B2FF7);

  /// Fonds sombres — noir et gris **neutres** (voir [NeoNeutrals]).
  static const bg = NeoNeutrals.black;
  static const surface1 = NeoNeutrals.gray900;
  static const surface2 = NeoNeutrals.gray800;

  /// Fonds clairs — blanc et gris **neutres**.
  static const bgLight = NeoNeutrals.white;
  static const surface1Light = NeoNeutrals.gray50;
  static const surface2Light = NeoNeutrals.gray100;

  static const _radius = 14.0;

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData light() => _build(Brightness.light);

  /// Le thème **NeoVibe** : les mêmes surfaces neutres, mais posées sur le
  /// dégradé du cycle de 24 h au lieu d'un fond plein.
  ///
  /// ### Ce qui change, et ce qui ne change surtout pas
  ///
  /// Il n'y a **aucune couleur nouvelle ici**. Le dégradé est un *fond
  /// d'écran* : tout ce qui porte du texte reste `NeoNeutrals`, en voile
  /// par-dessus. Le contraste est donc garanti **par construction**, à
  /// n'importe quelle heure — et non par un calcul qu'il faudrait refaire à
  /// chaque retouche de palette.
  ///
  /// C'est aussi pourquoi ce thème est **sombre** et le reste toute la
  /// journée : à midi le dégradé est pâle, et des surfaces claires par-dessus
  /// donneraient du blanc sur blanc. Un voile sombre lit sur les deux.
  ///
  /// ⚠️ **Les boutons ne suivent PAS l'heure.** Le cycle produit bien un accent
  /// horaire (`DayPalette.accent`), mais l'app garde le dégradé de marque —
  /// consigne de Jay du 2026-08-14 : « en conservant les boutons colorés déjà
  /// présents ». Deux couleurs d'action qui se disputeraient l'écran seraient
  /// un recul, pas une nouveauté.
  static ThemeData neovibe() => _build(Brightness.dark, overGradient: true);

  /// [overGradient] : le fond appartient au dégradé posé derrière l'app, pas
  /// au thème. Tout ce qui serait un aplat opaque devient transparent, sinon
  /// il masquerait exactement ce qu'on veut voir.
  static ThemeData _build(Brightness brightness, {bool overGradient = false}) {
    final isDark = brightness == Brightness.dark;
    final background = isDark ? bg : bgLight;
    final container = isDark ? surface1 : surface1Light;
    final field = isDark ? surface2 : surface2Light;
    final onBackground = isDark ? NeoNeutrals.white : NeoNeutrals.black;
    final muted = isDark ? NeoNeutrals.gray400 : NeoNeutrals.gray600;
    final divider = isDark ? NeoNeutrals.gray700 : NeoNeutrals.gray200;
    final outline = isDark ? NeoNeutrals.outlineDark : NeoNeutrals.outlineLight;

    // `fromSeed` fabrique TOUTES les nuances de surface en les teintant de la
    // graine — c'est sa raison d'être. On ne garde donc de lui que les rôles
    // colorés (erreur, conteneurs d'accent) et on réécrit **tous** les rôles
    // neutres à la main. Sans ça, `surfaceContainer`, `surfaceDim` et
    // consorts continuent d'arriver rosés dans les widgets Material qui les
    // consultent (Card, NavigationBar, Menu, DropdownMenu…), et le violet
    // revient par une porte qu'aucun `grep` d'hexadécimal ne montre.
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final scheme = base.copyWith(
      primary: accentPink,
      onPrimary: NeoNeutrals.white,
      secondary: accentOrange,
      tertiary: accentViolet,

      // Fonds et surfaces — neutres.
      surface: background,
      onSurface: onBackground,
      surfaceContainerLowest: background,
      surfaceContainerLow: container,
      surfaceContainer: container,
      surfaceContainerHigh: field,
      surfaceContainerHighest: field,
      surfaceDim: background,
      surfaceBright: field,
      onSurfaceVariant: muted,
      outline: outline,
      outlineVariant: divider,

      // Inversion (snackbars, infobulles) — neutre elle aussi.
      inverseSurface: isDark ? NeoNeutrals.white : NeoNeutrals.black,
      onInverseSurface: isDark ? NeoNeutrals.black : NeoNeutrals.white,

      // Le voile d'élévation de Material 3 : il repeint chaque surface élevée
      // d'un film de `primary`. Transparent, sinon toutes les feuilles et les
      // menus repartent en rosé après qu'on a neutralisé les gris.
      surfaceTint: Colors.transparent,
      shadow: NeoNeutrals.black,
      scrim: NeoNeutrals.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      // Sur le dégradé, le Scaffold ne peint plus rien : c'est ce qui met le
      // fond du cycle derrière les **60 Scaffold** de l'app sans en toucher un
      // seul. Le branchement tient en cette ligne et en `MaterialApp.builder`.
      scaffoldBackgroundColor: overGradient ? Colors.transparent : background,
      canvasColor: overGradient ? Colors.transparent : background,
      // Le système de mouvement, posé le 2026-08-14. Ces deux lignes pilotent
      // la durée ET l'allure des **46** navigations de l'app, sans toucher un
      // seul `MaterialPageRoute` — voir `NeoPageTransitionsBuilder`.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: NeoPageTransitionsBuilder(),
          TargetPlatform.iOS: NeoPageTransitionsBuilder(),
        },
      ),
      // Même raison que `surfaceTint` ci-dessus, au niveau du thème.
      applyElevationOverlayColor: false,
      appBarTheme: AppBarTheme(
        backgroundColor: overGradient ? Colors.transparent : background,
        foregroundColor: onBackground,
        surfaceTintColor: Colors.transparent,
        // Sans ça, l'AppBar change de gris dès qu'on fait défiler dessous.
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        // **Aucun fond** — décision de Jay, 2026-08-15 : « on supprime le fond
        // de la navbar et on laisse juste les boutons apparents ».
        //
        // Volontairement dans les TROIS thèmes, et pas seulement sur le
        // dégradé : c'est une décision sur la barre, pas sur un thème. La
        // faire dépendre du thème donnerait deux barres différentes à
        // maintenir, et le jour où l'une bougerait l'autre serait oubliée.
        //
        // ⚠️ Sans danger de collision avec le contenu : `bottomNavigationBar`
        // réserve sa place dans le `Scaffold`, le corps ne s'étend pas
        // dessous (il faudrait `extendBody: true`). On voit donc le fond de
        // l'app, jamais du texte qui défile derrière les icônes.
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
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
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? accentPink : muted,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),

      // --- Champs de saisie ---------------------------------------------
      // Remplissage ET bordure. Le remplissage situe le champ, la bordure le
      // délimite ; c'est la bordure qui garantit qu'il ne disparaît jamais
      // dans la page — voir le commentaire de `NeoNeutrals.outlineDark`.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
        hintStyle: TextStyle(color: muted),
        labelStyle: TextStyle(color: muted),
        prefixIconColor: muted,
        suffixIconColor: muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: outline),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: accentPink, width: 1.8),
        ),
      ),

      // --- Boutons -----------------------------------------------------
      // Le dégradé est injecté par `backgroundBuilder` : il s'applique donc à
      // TOUS les `FilledButton`/`OutlinedButton` de l'app sans toucher aux
      // 60+ appels existants.
      filledButtonTheme: FilledButtonThemeData(style: _filledStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _outlinedStyle(onBackground, muted),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accentPink),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: onBackground),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        // Les FAB portent le dégradé via `GradientFab` (widget dédié) : le
        // thème ne sert qu'aux FAB restés standards.
        backgroundColor: accentPink,
        foregroundColor: NeoNeutrals.white,
      ),

      // --- Contrôles ----------------------------------------------------
      // Le rose ne dit plus qu'une chose : « ceci est actif ». Au repos, tout
      // est neutre. (Choix de Jay, 2026-08-14.)
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? NeoNeutrals.white
              : (isDark ? NeoNeutrals.gray400 : NeoNeutrals.white),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentPink : field,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentPink : outline,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? accentPink
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(NeoNeutrals.white),
        side: BorderSide(color: outline, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentPink : outline,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accentPink,
        inactiveTrackColor: field,
        thumbColor: accentPink,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accentPink,
        linearTrackColor: field,
      ),
      dividerTheme: DividerThemeData(color: divider, space: 1, thickness: 1),
      chipTheme: ChipThemeData(
        backgroundColor: field,
        selectedColor: accentPink.withValues(alpha: .25),
        side: BorderSide(color: outline),
        labelStyle: TextStyle(color: onBackground),
      ),
      cardTheme: CardThemeData(
        color: container,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: BorderSide(color: divider),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: container,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: container,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: container,
        surfaceTintColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(container),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        textColor: onBackground,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? NeoNeutrals.gray800 : NeoNeutrals.black,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(color: NeoNeutrals.white, fontSize: 12),
      ),
    );
  }

  /// Bouton plein : fond transparent + dégradé peint par `backgroundBuilder`.
  ///
  /// Le texte reste blanc dans les deux thèmes : il ne se pose jamais sur la
  /// page, toujours sur le dégradé.
  static ButtonStyle _filledStyle() {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: shape,
      backgroundColor: Colors.transparent,
      foregroundColor: NeoNeutrals.white,
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
  ///
  /// ⚠️ Le texte suit le thème, il n'est PAS blanc en dur. Il se pose sur le
  /// fond de l'écran (le centre du bouton est repeint à
  /// `scaffoldBackgroundColor`) : en blanc fixe, il était **invisible en thème
  /// clair**. Bug corrigé le 2026-08-14 — il datait de l'ajout du thème clair
  /// le 2026-08-10 et n'a jamais levé la moindre erreur.
  static ButtonStyle _outlinedStyle(Color foreground, Color disabled) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: shape,
      side: BorderSide.none,
      foregroundColor: foreground,
      disabledForegroundColor: disabled,
    ).copyWith(
      backgroundBuilder: (context, states, child) {
        final isDisabled = states.contains(WidgetState.disabled);
        return Container(
          decoration: BoxDecoration(
            gradient: isDisabled
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
