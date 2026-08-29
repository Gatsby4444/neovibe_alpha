import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'palette.dart';
import 'typography.dart';

/// Échelle de gris **strictement neutre** — `R == G == B` sur chaque valeur.
///
/// Consigne de Jay, 2026-08-14 : « on refait un thème clair et un thème sombre
/// propre, au niveau des couleurs surtout : du noir, du blanc et du gris […]
/// tu me retires ton violet terne. On veut quelque chose de tranché et épuré. »
///
/// ## ⚠️ Ce que cette échelle EST devenue le 2026-08-29
///
/// Elle n'est plus « la palette de l'app » : les couleurs d'habillage vivent
/// désormais dans [NeoPalette], une par identité. Elle garde **deux** usages,
/// et seulement ceux-là :
///
/// 1. **Les deux identités neutres** (`sombre`, `clair`) sont bâties dessus —
///    c'est leur définition même, et la règle `R == G == B` continue de s'y
///    appliquer sans exception.
/// 2. **Les surfaces qui restent sombres quelle que soit l'identité** : écrans
///    caméra, visionneuses de Vibes, recadrage d'avatar. Là, le noir n'habille
///    pas l'app — il **efface le décor pour laisser le contenu porter la
///    lumière**. Une couleur d'identité y serait une faute : on regarderait le
///    thème au lieu de la photo.
///
/// 🔴 **Hors de ces deux cas, un écran ne doit jamais lire cette classe.** Il
/// lit `context.palette`. Une couleur écrite en dehors des palettes est une
/// couleur qui ne suivra pas les changements d'identité — et personne ne le
/// verra tant qu'il n'aura pas changé de thème.
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
}

/// La palette en vigueur, transportée par le thème.
///
/// ⚠️ **Pourquoi une extension de thème et pas un provider.** Un widget qui
/// lirait un provider de palette redemanderait la couleur à une source
/// différente de celle qui a construit le `ThemeData` — donc deux chemins vers
/// la même donnée, et un désaccord garanti le jour où l'un change. Ici il n'y
/// en a qu'un : `MaterialApp` construit le thème depuis la palette, et le
/// thème la transporte jusqu'au widget.
@immutable
class NeoPaletteTheme extends ThemeExtension<NeoPaletteTheme> {
  const NeoPaletteTheme({required this.palette, required this.identity});

  /// La palette réellement en vigueur (jour ou nuit selon le système).
  final NeoPalette palette;

  /// L'identité choisie — ce qui permet à une surface toujours sombre de
  /// demander la palette de NUIT de la même identité.
  final NeoIdentity identity;

  @override
  NeoPaletteTheme copyWith({NeoPalette? palette, NeoIdentity? identity}) =>
      NeoPaletteTheme(
        palette: palette ?? this.palette,
        identity: identity ?? this.identity,
      );

  /// Pas d'interpolation : une palette ne se mélange pas à une autre.
  ///
  /// ⚠️ Un fondu entre deux identités produirait, à mi-chemin, des couleurs qui
  /// n'appartiennent à aucune des deux — et dont personne n'a vérifié le
  /// contraste. On bascule net.
  @override
  NeoPaletteTheme lerp(ThemeExtension<NeoPaletteTheme>? other, double t) =>
      t < 0.5 ? this : (other as NeoPaletteTheme? ?? this);
}

/// L'accès des écrans aux couleurs de l'identité.
extension NeoPaletteAccess on BuildContext {
  /// La palette en vigueur. **C'est le seul chemin qu'un écran doit emprunter.**
  NeoPalette get palette =>
      Theme.of(this).extension<NeoPaletteTheme>()?.palette ??
      NeoPalettes.sombre;

  /// La palette **de nuit** de l'identité courante.
  ///
  /// Pour les surfaces qui restent sombres quel que soit le thème — caméra,
  /// visionneuses. Elles ont besoin d'un accent lisible sur du noir, même
  /// quand l'app est en clair : sans ça, le magenta de jour d'Aurore
  /// disparaîtrait sur l'écran de capture.
  NeoPalette get darkPalette =>
      (Theme.of(this).extension<NeoPaletteTheme>()?.identity ??
              NeoIdentity.sombre)
          .palette(Brightness.dark);
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

/// Le thème NeoVibe : **comment Material se sert d'une palette**.
///
/// ## Ce qui a changé le 2026-08-29
///
/// Avant, ce fichier portait à la fois les couleurs ET leur usage : les
/// hexadécimaux du dégradé de marque et des accents y étaient écrits en dur,
/// et les trois thèmes se distinguaient par un `if (isDark)` répété vingt
/// fois. Ajouter une identité aurait voulu dire relire ces vingt endroits.
///
/// Désormais **il n'y a plus qu'un seul thème**, construit depuis une
/// [NeoPalette] (voir `palette.dart`). Ajouter une identité, c'est ajouter une
/// palette — ce fichier ne bouge pas.
///
/// ## Répartition des rôles, tenue depuis le 2026-08-14
///
/// - **Les surfaces portent l'écran** — fonds, cartes, champs, textes,
///   bordures. Tout vient de la palette, aucun hexadécimal ici.
/// - **La couleur ne signale qu'une chose : ce qui est actif.** Bouton
///   d'action, champ au focus, interrupteur enclenché, onglet courant.
///
/// Les écrans caméra et les visionneuses restent sombres quelle que soit
/// l'identité : c'est le contenu qui doit porter la lumière.
abstract final class NeoTheme {
  /// Le rayon de coin des éléments interactifs (champs, boutons).
  ///
  /// Les cartes et les tuiles ont le leur dans [NeoRadius] : un bouton et une
  /// story n'ont aucune raison d'être arrondis pareil, et sur une identité
  /// ronde c'est précisément le dosage qui évite l'effet enfantin.
  static const _radius = NeoRadius.sm;

  /// Construit le thème d'une identité, pour la luminosité demandée.
  static ThemeData of(NeoIdentity identity, Brightness brightness) =>
      _build(identity, identity.palette(brightness));

  static ThemeData _build(NeoIdentity identity, NeoPalette p) {
    final isDark = p.isDark;
    // Le cycle pose son dégradé DERRIÈRE l'app : tout aplat opaque devient
    // transparent, sinon il masquerait exactement ce qu'on veut voir. Le
    // branchement tient en cette ligne et en `MaterialApp.builder`.
    final overGradient = identity.fondDuCycle;

    // `fromSeed` fabrique TOUTES les nuances de surface en les teintant de la
    // graine — c'est sa raison d'être. On ne garde donc de lui que les rôles
    // colorés (erreur, conteneurs d'accent) et on réécrit **tous** les rôles
    // de surface à la main. Sans ça, `surfaceContainer`, `surfaceDim` et
    // consorts continuent d'arriver teintés dans les widgets Material qui les
    // consultent (Card, NavigationBar, Menu, DropdownMenu…), et la teinte
    // revient par une porte qu'aucun `grep` d'hexadécimal ne montre.
    final base = ColorScheme.fromSeed(
      seedColor: p.action,
      brightness: p.brightness,
    );
    final scheme = base.copyWith(
      primary: p.action,
      onPrimary: p.onAction,
      secondary: p.cool,
      tertiary: p.warm,

      surface: p.ground,
      onSurface: p.ink,
      surfaceContainerLowest: p.ground,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.field,
      surfaceContainerHighest: p.field,
      surfaceDim: p.ground,
      surfaceBright: p.field,
      onSurfaceVariant: p.inkMuted,
      outline: p.outline,
      outlineVariant: p.line,

      // Inversion (snackbars, infobulles).
      inverseSurface: p.ink,
      onInverseSurface: p.ground,

      // Le voile d'élévation de Material 3 : il repeint chaque surface élevée
      // d'un film de `primary`. Transparent, sinon toutes les feuilles et les
      // menus repartent teintés après qu'on a posé les surfaces.
      surfaceTint: Colors.transparent,
      shadow: NeoNeutrals.black,
      scrim: NeoNeutrals.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      extensions: [NeoPaletteTheme(palette: p, identity: identity)],
      textTheme: NeoType.scale(ink: p.ink, muted: p.inkMuted),
      // Sur le dégradé, le Scaffold ne peint plus rien : c'est ce qui met le
      // fond du cycle derrière les **60 Scaffold** de l'app sans en toucher un
      // seul.
      scaffoldBackgroundColor: overGradient ? Colors.transparent : p.ground,
      canvasColor: overGradient ? Colors.transparent : p.ground,
      // Le système de mouvement, posé le 2026-08-14. Ces deux lignes pilotent
      // la durée ET l'allure de TOUTES les navigations de l'app, sans toucher un
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
        backgroundColor: overGradient ? Colors.transparent : p.ground,
        foregroundColor: p.ink,
        // Le titre d'AppBar est un titre de SECTION : c'est un des rares
        // endroits où la ronde a sa place (voir `NeoType`).
        titleTextStyle: TextStyle(
          fontFamily: NeoType.display,
          fontFamilyFallback: NeoType.fallback,
          fontSize: 22,
          height: 1.15,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: p.ink,
        ),
        // Depuis que l'app est en **bord à bord permanent** (2026-08-15), elle
        // dessine derrière les barres système : c'est donc à elle de dire de
        // quelle couleur doivent être leurs icônes.
        //
        // ⚠️ Sans ça, une identité claire afficherait des icônes claires sur du
        // blanc — invisibles. Le défaut ne se verrait que dans une identité sur
        // deux, donc pas au premier test.
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          // iOS lit `statusBarBrightness`, qui désigne le FOND et non les
          // icônes : les deux sont donc opposés, ce n'est pas une faute.
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
        ),
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
        // Volontairement dans TOUTES les identités : c'est une décision sur la
        // barre, pas sur un thème. La faire dépendre de l'identité donnerait
        // plusieurs barres à maintenir, et le jour où l'une bougerait les
        // autres seraient oubliées.
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // L'indicateur ne peut pas porter de dégradé : c'est l'icône
        // sélectionnée qui le fait (voir `GradientIcon` dans home_shell).
        indicatorColor: p.action.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: NeoType.body,
            fontFamilyFallback: NeoType.fallback,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? p.action
                : p.inkMuted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? p.action
                : p.inkMuted,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),

      // --- Champs de saisie ---------------------------------------------
      // Remplissage ET bordure. Le remplissage situe le champ, la bordure le
      // délimite ; c'est la bordure qui garantit qu'il ne disparaît jamais
      // dans la page — voir le commentaire de `NeoPalette.outline`.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.field,
        // L'aération commence ici : un champ serré fait « formulaire », un
        // champ respirant fait « app ».
        contentPadding: const EdgeInsets.symmetric(
          horizontal: NeoSpace.lg,
          vertical: NeoSpace.lg,
        ),
        hintStyle: TextStyle(color: p.inkMuted),
        labelStyle: TextStyle(color: p.inkMuted),
        prefixIconColor: p.inkMuted,
        suffixIconColor: p.inkMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: p.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: p.outline),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: p.action, width: 1.8),
        ),
      ),

      // --- Boutons -----------------------------------------------------
      // Le dégradé est injecté par `backgroundBuilder` : il s'applique donc à
      // TOUS les `FilledButton`/`OutlinedButton` de l'app sans toucher aux
      // 60+ appels existants.
      filledButtonTheme: FilledButtonThemeData(style: _filledStyle(p)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedStyle(p)),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.action),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.ink),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        // Les FAB portent le dégradé via `GradientFab` (widget dédié) : le
        // thème ne sert qu'aux FAB restés standards.
        backgroundColor: p.action,
        foregroundColor: p.onAction,
      ),

      // --- Contrôles ----------------------------------------------------
      // La couleur d'action ne dit qu'une chose : « ceci est actif ». Au repos,
      // tout est neutre. (Choix de Jay, 2026-08-14.)
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? p.onAction
              : (isDark ? p.inkMuted : p.surface),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.action : p.field,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.action : p.outline,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? p.action : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(p.onAction),
        side: BorderSide(color: p.outline, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.action : p.outline,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.action,
        inactiveTrackColor: p.field,
        thumbColor: p.action,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.action,
        linearTrackColor: p.field,
      ),
      dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: 1),
      chipTheme: ChipThemeData(
        backgroundColor: p.field,
        selectedColor: p.action.withValues(alpha: .25),
        side: BorderSide(color: p.outline),
        labelStyle: TextStyle(
          fontFamily: NeoType.body,
          fontFamilyFallback: NeoType.fallback,
          color: p.ink,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          side: BorderSide(color: p.line),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(p.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.inkMuted,
        textColor: p.ink,
        // Aération : la valeur Material par défaut colle les lignes entre
        // elles, ce qui donne exactement la « liste de containers qui
        // s'enchaînent » dont Jay veut sortir.
        minVerticalPadding: NeoSpace.md,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? p.field : p.ink,
          borderRadius: BorderRadius.circular(NeoRadius.sm),
        ),
        textStyle: TextStyle(
          fontFamily: NeoType.body,
          fontFamilyFallback: NeoType.fallback,
          color: isDark ? p.ink : p.ground,
          fontSize: 12,
        ),
      ),
    );
  }

  /// Bouton plein : fond transparent + dégradé peint par `backgroundBuilder`.
  ///
  /// Le texte prend `onAction` : il ne se pose jamais sur la page, toujours sur
  /// le dégradé de l'identité. Le déduire de la luminosité serait faux — sur le
  /// beige de Sable il doit être clair, sur le jaune d'Aurore il doit être
  /// sombre, et les deux sont des identités « claires ».
  static ButtonStyle _filledStyle(NeoPalette p) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return FilledButton.styleFrom(
      // ⚠️ **`Size.fromHeight(52)` vaut `Size(double.infinity, 52)`** — une
      // largeur minimale **INFINIE**, pas « seulement une hauteur ». Le nom du
      // constructeur dit le contraire de ce qu'il fait.
      //
      // C'est **voulu** : c'est ce qui rend pleine largeur les ~40 gros boutons
      // de l'app (connexion, envoi, réglages) sans que personne n'ait à
      // l'écrire. Sous un parent à largeur bornée, l'infini est raboté à la
      // place disponible.
      //
      // 🔴 **Mais dans une `Row`, il FAUT un `Expanded`, un `Flexible` ou un
      // `SizedBox`.** Une `Row` ne borne pas la largeur de ses enfants
      // non-flexibles : le bouton réclame alors l'infini et **est peint hors de
      // l'écran**. En debug Flutter lève ; en **release l'assertion est
      // compilée hors du binaire**, donc rien ne le signale.
      //
      // Constaté le 2026-08-17 : la carte « X veut se connecter avec toi »
      // rendait bien ses deux boutons, et Jay n'a vu que « Refuser » — la
      // demande d'ami était impossible à accepter. Inventaire fait ce jour-là :
      // 8 `FilledButton` dans une `Row`, 7 protégés par un `Expanded` **par
      // habitude**, 1 nu. La règle n'était écrite nulle part ; elle l'est ici.
      //
      // Gardé par `test/filled_button_row_test.dart`.
      minimumSize: const Size.fromHeight(52),
      shape: shape,
      backgroundColor: Colors.transparent,
      foregroundColor: p.onAction,
      disabledBackgroundColor: Colors.transparent,
      disabledForegroundColor: p.onAction.withValues(alpha: 0.38),
      elevation: 0,
      shadowColor: Colors.transparent,
      textStyle: const TextStyle(
        fontFamily: NeoType.body,
        fontFamilyFallback: NeoType.fallback,
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
      ),
    ).copyWith(
      backgroundBuilder: (context, states, child) {
        final disabled = states.contains(WidgetState.disabled);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: disabled ? p.signatureAttenuee : p.signatureCourte,
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
  static ButtonStyle _outlinedStyle(NeoPalette p) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: shape,
      side: BorderSide.none,
      foregroundColor: p.ink,
      disabledForegroundColor: p.inkMuted,
      textStyle: const TextStyle(
        fontFamily: NeoType.body,
        fontFamilyFallback: NeoType.fallback,
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
      ),
    ).copyWith(
      backgroundBuilder: (context, states, child) {
        final isDisabled = states.contains(WidgetState.disabled);
        return Container(
          decoration: BoxDecoration(
            gradient: isDisabled ? p.signatureAttenuee : p.signatureCourte,
            borderRadius: BorderRadius.circular(_radius),
          ),
          padding: const EdgeInsets.all(1.5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // ⚠️ Le centre reprend le fond de l'ÉCRAN, pas la surface : sur
              // le cycle, `scaffoldBackgroundColor` est transparent et c'est le
              // dégradé qui apparaît au centre — ce qui est l'effet voulu.
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
