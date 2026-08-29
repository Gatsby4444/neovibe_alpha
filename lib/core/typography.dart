import 'package:flutter/material.dart';

/// La typographie de NeoVibe — **direction « le rond »**, choisie par Jay le
/// 2026-08-29.
///
/// ## Le constat qui a déclenché ce fichier
///
/// Jusqu'au 2026-08-29, l'app ne déclarait **aucune police**. Elle tournait
/// donc sur Roboto, celle qu'Android donne par défaut à toutes les
/// applications. Aucune identité typographique n'avait jamais été posée — et
/// c'est la première cause du « fade » signalé par Jay, qu'aucun fond coloré
/// ne pouvait compenser.
///
/// ## Les deux voix, et la règle qui les sépare
///
/// | Police | Où elle sert | Où elle ne sert JAMAIS |
/// |---|---|---|
/// | **Fredoka** | titres de section, chiffres mis en avant | le texte courant, les libellés, les champs |
/// | **Figtree** | tout le reste | les titres |
///
/// ⚠️ **C'est cette frontière qui tient le risque « enfantin »**, pas le choix
/// de la police. Consigne de Jay dans le même message : *« il faut aérer pour
/// ne pas faire trop enfantin »*. Une police ronde étalée sur des paragraphes
/// entiers fait un jeu pour enfants ; la même, réservée aux titres courts et
/// posée dans du vide, fait une marque.
///
/// Les trois autres leviers, appliqués ici :
///
/// 1. **Les graisses restent moyennes.** Fredoka monte à 600, jamais au-delà,
///    et le corps de texte vit en 400. Le gras est un accent, pas un ton.
/// 2. **Les interlignes sont larges** — 1,45 sur le texte courant. C'est le
///    « vide » de la consigne : il se gagne surtout entre les lignes.
/// 3. **L'échelle est courte.** Sept tailles, pas quinze. Une échelle longue
///    produit des écarts qu'on ne voit pas, donc une hiérarchie qu'on ne lit
///    pas.
abstract final class NeoType {
  /// Les titres. Ronde, chaleureuse — et **rationnée**.
  static const display = 'Fredoka';

  /// Tout le reste. Neutre, très lisible en petit, accents français dessinés.
  static const body = 'Figtree';

  /// Le repli si une police manquait à l'appel.
  ///
  /// ⚠️ Sans repli déclaré, une police absente ne lève **aucune erreur** :
  /// Flutter retombe en silence sur la police système, et le défaut ressemble
  /// à un choix. C'est exactement l'état de l'app avant aujourd'hui.
  static const fallback = <String>['Roboto', 'sans-serif'];

  /// L'échelle, appliquée à toute l'app par `ThemeData.textTheme`.
  ///
  /// [ink] porte le texte principal, [muted] le secondaire. Les deux viennent
  /// de la palette : aucune couleur n'est écrite ici.
  static TextTheme scale({required Color ink, required Color muted}) {
    // Titres — Fredoka. Serrés en approche : une ronde à taille de titre
    // paraît lâche si on n'y touche pas.
    TextStyle titre(double size, {double weight = 600, double height = 1.12}) =>
        TextStyle(
          fontFamily: display,
          fontFamilyFallback: fallback,
          fontSize: size,
          height: height,
          fontWeight: FontWeight.values[(weight ~/ 100) - 1],
          letterSpacing: size >= 28 ? -0.5 : -0.2,
          color: ink,
        );

    // Textes — Figtree, interlignes larges.
    TextStyle texte(
      double size, {
      FontWeight weight = FontWeight.w400,
      double height = 1.45,
      Color? color,
      double spacing = 0,
    }) => TextStyle(
      fontFamily: body,
      fontFamilyFallback: fallback,
      fontSize: size,
      height: height,
      fontWeight: weight,
      letterSpacing: spacing,
      color: color ?? ink,
    );

    return TextTheme(
      // --- Fredoka : les trois tailles de titre --------------------------
      displayLarge: titre(40),
      displayMedium: titre(34),
      displaySmall: titre(28),
      headlineLarge: titre(26),
      headlineMedium: titre(23),
      headlineSmall: titre(20),

      // --- Figtree : titres de bloc et de liste --------------------------
      //
      // ⚠️ Les `title*` restent en Figtree, et ce n'est pas un oubli : ils
      // servent aux LIGNES de liste (`ListTile.title`), qui sont du contenu,
      // pas des titres de section. Les passer en Fredoka mettrait de la ronde
      // sur chaque nom d'ami — l'effet « app pour enfants » en une ligne.
      titleLarge: texte(19, weight: FontWeight.w600, height: 1.3),
      titleMedium: texte(16, weight: FontWeight.w600, height: 1.35),
      titleSmall: texte(14, weight: FontWeight.w600, height: 1.35),

      // --- Figtree : le texte courant ------------------------------------
      bodyLarge: texte(16),
      bodyMedium: texte(14.5),
      bodySmall: texte(13, color: muted, height: 1.4),

      // --- Figtree : les libellés ----------------------------------------
      //
      // Un chouïa d'approche POSITIVE sur les petites tailles : en dessous de
      // 13 px, des lettres serrées se lisent comme une tache.
      labelLarge: texte(14.5, weight: FontWeight.w600, height: 1.2),
      labelMedium: texte(
        12.5,
        weight: FontWeight.w500,
        height: 1.2,
        spacing: 0.2,
      ),
      labelSmall: texte(
        11.5,
        weight: FontWeight.w500,
        height: 1.2,
        spacing: 0.4,
        color: muted,
      ),
    );
  }
}

/// Les styles qui ne sont pas dans l'échelle Material, mais que l'app répète.
///
/// ⚠️ Ils vivent ici et pas dans un écran : un style écrit dans un écran n'est
/// réutilisable par personne, et se retrouve recopié — c'est exactement ce
/// qu'on a constaté le 2026-08-25 sur `cardByIdProvider`.
extension NeoTextStyles on BuildContext {
  /// Le titre d'une **section** (« Cercle », « Ping »). Fredoka, grand, aéré.
  TextStyle get sectionTitle =>
      Theme.of(this).textTheme.displaySmall ?? const TextStyle();

  /// La ligne de contexte sous un titre de section : « 14 amis · 4 croisés ».
  ///
  /// Chiffres **tabulaires** : sans ça, un compteur qui passe de 9 à 10 fait
  /// bouger toute la ligne.
  TextStyle get sectionMeta =>
      (Theme.of(this).textTheme.bodySmall ?? const TextStyle()).copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Un pseudo dans une tuile ou une carte.
  TextStyle get pseudo =>
      Theme.of(this).textTheme.titleSmall ?? const TextStyle();

  /// Le `@tag` sous un pseudo.
  TextStyle get tagName =>
      (Theme.of(this).textTheme.labelSmall ?? const TextStyle());
}

/// L'échelle d'espacement — le « vide » de la consigne d'aération.
///
/// ⚠️ **Une échelle, pas des nombres au cas par cas.** Des marges choisies
/// écran par écran donnent des écarts de 11, 13 et 15 px que personne ne
/// remarque un par un, et qui font ensemble une interface qui « fait pas
/// fini ».
abstract final class NeoSpace {
  /// Entre deux éléments collés par nature (une icône et son libellé).
  static const xs = 4.0;

  /// Dans un même bloc (un pseudo et son tag).
  static const sm = 8.0;

  /// Entre deux blocs d'une même carte.
  static const md = 12.0;

  /// La marge intérieure de référence d'une carte ou d'une tuile.
  static const lg = 16.0;

  /// La marge de l'écran, et l'écart entre deux cartes.
  static const xl = 20.0;

  /// Entre deux SECTIONS. C'est ce pas-là qui aère vraiment : le doubler
  /// change une page dense en page respirante sans toucher à rien d'autre.
  static const xxl = 32.0;

  /// Au-dessus d'un titre de section, quand il suit du contenu.
  static const section = 40.0;
}

/// Les rayons de coin, une fois pour toute l'app.
///
/// ⚠️ Sur une identité ronde, le rayon est un **choix de dosage** : tout
/// arrondir au maximum est précisément ce qui fait basculer dans l'enfantin.
/// Les pastilles sont pleinement rondes, les cartes le sont modérément.
abstract final class NeoRadius {
  /// Champs, petites puces.
  static const sm = 12.0;

  /// Cartes, tuiles, feuilles.
  static const md = 18.0;

  /// Grandes cartes (une story, une Vibe).
  static const lg = 22.0;

  /// Ce qui est vraiment rond : pastilles d'état, boutons pilule.
  static const pill = 999.0;
}
