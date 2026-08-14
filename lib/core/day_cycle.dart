/// Le **cycle de 24 h** du thème NeoVibe : la couleur de l'app en fonction de
/// l'heure.
///
/// Cadrage complet et table des ancrages : `docs/theme-neovibe-cycle.md`.
///
/// ## Le principe : une fonction pure de l'heure
///
/// [at] est une **fonction pure** de `t`, l'heure décimale sur 24 h. Pas
/// d'états, pas de paliers, pas de fondu — on interpole la palette **par** `t`.
///
/// C'est le choix structurant, et il vient d'une phrase de Jay : il veut que ça
/// change *« comme le mouvement du soleil dans le ciel — on remarque que cela
/// change mais c'est tellement lent qu'on ne le voit pas vraiment »*. Une
/// transition, même longue, a un début et une fin : elle se remarque. Le soleil
/// ne transitionne pas, il *est* quelque part.
///
/// Trois conséquences, et ce sont elles qui ont fait choisir ce modèle :
///
/// 1. **Aucune transition à écrire ni à déboguer** — le problème disparaît au
///    lieu d'être résolu.
/// 2. **Aucun instant où « ça change »**, puisque ça change en permanence.
///    ~0,3° de teinte par minute : moins d'un degré sur une session de deux
///    minutes, sous le seuil de perception.
/// 3. **Déterministe, donc testable exhaustivement** — voir
///    `test/day_cycle_test.dart`, qui vérifie les 1440 minutes de la journée.
///    C'est ce qui garde une retouche de palette à deux minutes de travail :
///    sans ce test, chaque changement de couleur obligerait à repasser tous les
///    écrans à la main, et au troisième plus personne ne le ferait.
///
/// ## Interpolation en OkLab, jamais en sRVB
///
/// Interpoler `#292F91` (bleu profond) vers `#FD8D67` (orange chaud) canal par
/// canal passe par un **gris-brun mort**. En OkLab le chemin reste saturé et
/// traverse des teintes plausibles. C'est le seul endroit de ce fichier où il
/// ne faut pas faire d'économie : c'est ce qui sépare un rendu « cher » d'un
/// rendu bricolé.
///
/// ⚠️ Ne **jamais** remplacer les interpolations d'ici par `Color.lerp` : il
/// travaille en sRVB.
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

/// Une couleur dans l'espace **OkLab** — perceptuellement uniforme.
///
/// Interne au cycle : l'extérieur ne manipule que des [Color].
class _Lab {
  const _Lab(this.l, this.a, this.b);

  final double l;
  final double a;
  final double b;

  /// Chroma : la distance à l'axe des gris. C'est « à quel point la couleur
  /// est colorée », indépendamment de sa clarté.
  double get chroma => math.sqrt(a * a + b * b);

  /// Teinte, en radians.
  double get hue => math.atan2(b, a);

  static _Lab lerp(_Lab x, _Lab y, double t) =>
      _Lab(x.l + (y.l - x.l) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t);

  static _Lab fromHueChroma(double hue, double chroma, double lightness) =>
      _Lab(lightness, chroma * math.cos(hue), chroma * math.sin(hue));
}

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _linearToSrgb(double c) => c <= 0.0031308
    ? 12.92 * c
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

double _cbrt(double x) =>
    x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

_Lab _toLab(Color c) {
  final r = _srgbToLinear((c.r * 255).round() / 255);
  final g = _srgbToLinear((c.g * 255).round() / 255);
  final b = _srgbToLinear((c.b * 255).round() / 255);
  final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return _Lab(
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

Color _toColor(_Lab lab) {
  final l = _cube(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b);
  final m = _cube(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b);
  final s = _cube(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b);
  int chan(double v) {
    final srgb = _linearToSrgb(v.clamp(0.0, 1.0));
    return (srgb.clamp(0.0, 1.0) * 255).round();
  }

  return Color.fromARGB(
    255,
    chan(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    chan(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    chan(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
  );
}

double _cube(double x) => x * x * x;

/// Luminance relative WCAG — sert au calcul de contraste, pas au rendu.
double _relativeLuminance(Color c) {
  final r = _srgbToLinear((c.r * 255).round() / 255);
  final g = _srgbToLinear((c.g * 255).round() / 255);
  final b = _srgbToLinear((c.b * 255).round() / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// Rapport de contraste WCAG entre deux couleurs opaques.
double contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Distance **perceptuelle** entre deux couleurs (ΔE OkLab).
///
/// Contrairement à une différence de canaux RVB, elle correspond à ce que
/// l'œil ressent : deux couleurs séparées de la même distance paraissent
/// également différentes, qu'elles soient sombres ou claires.
///
/// C'est ce qui permet d'**énoncer « imperceptible » comme une assertion** au
/// lieu d'une impression — voir `test/day_cycle_test.dart`.
double perceptualDistance(Color a, Color b) {
  final x = _toLab(a);
  final y = _toLab(b);
  final dl = x.l - y.l;
  final da = x.a - y.a;
  final db = x.b - y.b;
  return math.sqrt(dl * dl + da * da + db * db);
}

/// Un ancrage : la couleur du fond à une heure donnée.
class DayAnchor {
  const DayAnchor(this.hour, this.top, this.bottom, this.label);

  /// Heure locale, 0–24.
  final double hour;

  final Color top;
  final Color bottom;

  /// Nom de la palette d'origine — sert au diagnostic et à l'écran d'aperçu.
  final String label;
}

/// La palette du moment.
class DayPalette {
  const DayPalette({
    required this.hour,
    required this.top,
    required this.middle,
    required this.bottom,
    required this.accent,
    required this.label,
  });

  final double hour;

  /// Les **trois** arrêts du fond, de haut en bas.
  final Color top;
  final Color middle;
  final Color bottom;

  /// Couleur d'action, garantie lisible sous du texte blanc.
  final Color accent;

  /// L'ancrage dont on est le plus proche — pour l'écran d'aperçu.
  final String label;
}

/// Le cycle.
abstract final class DayCycle {
  /// Les ancrages, triés par heure.
  ///
  /// **Version 2, 2026-08-15.** Jay a trié lui-même les palettes en
  /// `matin` / `midi` / `soir` (`docs/images/`) après avoir rejeté la v1 :
  /// *« il y a beaucoup de bleu, souvent présent »*.
  ///
  /// Ce que sa répartition change n'est pas une teinte, c'est une **référence**
  /// : en plaçant Jungle à midi, il déplace le sujet du **ciel** vers la
  /// **végétation**. La v1 racontait un ciel du matin au soir ; celle-ci
  /// raconte un paysage. C'est ça, « naturelle, qui respire ».
  ///
  /// ⚠️ **C'est le seul endroit à éditer pour changer les couleurs.** Le moteur
  /// ne bouge pas quand la palette bouge — et le test des 1440 minutes dit
  /// immédiatement si un nouvel ancrage casse la lisibilité.
  static const anchors = <DayAnchor>[
    // ⚠️ Cadence de DEUX heures, uniforme, et ce n'est pas une commodité.
    //
    // La v2 plaçait Deep Ocean à 5 h et Velvet Sunset à 6 h : le lever se
    // faisait donc en UNE heure, pour le plus grand écart de couleur de toute
    // la journée. Le test des 1440 minutes l'a refusé (ΔE 0,0091 par minute,
    // plus du double du seuil) — c'est-à-dire un changement qu'on VOIT, alors
    // que toute la conception vise l'inverse.
    //
    // Mesuré : parcourir la journée entière demande ~14 h de « budget » au
    // rythme imperceptible, et on en a 24. La distance n'était pas le
    // problème, sa répartition l'était. Deux ancrages décalés (3 h → 2 h et
    // 5 h → 4 h) suffisent à ce que chaque segment tienne dans le sien.
    DayAnchor(0, Color(0xFF04150F), Color(0xFF06231D), 'Nuit'),
    DayAnchor(2, Color(0xFF071512), Color(0xFF0C342C), 'Jungle sombre'),
    DayAnchor(4, Color(0xFF1B0B3D), Color(0xFF5B22C8), 'Deep Ocean'),
    DayAnchor(6, Color(0xFFA92655), Color(0xFFFD8D67), 'Velvet Sunset'),
    DayAnchor(8, Color(0xFFDD7A83), Color(0xFFE8BFC3), 'Blush Silk'),
    DayAnchor(10, Color(0xFF292F91), Color(0xFF4CA8DD), 'Azuria'),
    DayAnchor(12, Color(0xFF076653), Color(0xFFE2FBCE), 'Jungle'),
    DayAnchor(14, Color(0xFF7AABFF), Color(0xFFFF9AEF), 'Cotton Candy'),
    DayAnchor(16, Color(0xFF708F96), Color(0xFFAA895F), 'Muted Olive Sky'),
    DayAnchor(18, Color(0xFFBC430D), Color(0xFFF09410), 'Desert'),
    DayAnchor(20, Color(0xFF6968A6), Color(0xFFCF9893), 'Lavender Dusk'),
    DayAnchor(22, Color(0xFF034C36), Color(0xFF003332), 'Deep Forest'),
    DayAnchor(24, Color(0xFF04150F), Color(0xFF06231D), 'Nuit'),
  ];

  /// Renflement de l'arrêt du milieu.
  ///
  /// Sans lui, un troisième arrêt posé au milieu **ne changerait
  /// strictement rien** : il tomberait pile sur la droite qui joint les deux
  /// autres. Ce qui donne sa matière au dégradé, c'est que la bande médiane est
  /// **plus colorée** que la moyenne — comme la bande d'horizon d'un vrai ciel.
  static const _middleChromaBoost = 1.28;

  /// Et très légèrement plus claire, pour que la lumière semble venir de la
  /// bande plutôt que du bord.
  static const _middleLightnessLift = 0.025;

  /// Position de l'arrêt du milieu, 0 = haut, 1 = bas.
  ///
  /// 0,55 et non 0,5 : la bande intéressante d'un paysage est sous le milieu
  /// de l'image, pas au centre géométrique.
  static const middleStop = 0.55;

  /// Chroma de l'accent. Assez tenue pour que la couleur reste franche.
  static const _accentChroma = 0.15;

  /// Contraste minimum exigé de l'accent sous du **texte blanc**.
  static const accentMinContrast = 4.5;

  /// La palette à l'heure [hours] (0–24, les valeurs hors bornes sont
  /// ramenées dans la journée : 25 h vaut 1 h).
  static DayPalette at(double hours) {
    final t = hours % 24;
    var i = 0;
    while (i < anchors.length - 2 && anchors[i + 1].hour <= t) {
      i++;
    }
    final a = anchors[i];
    final b = anchors[i + 1];
    final span = b.hour - a.hour;
    final k = span <= 0 ? 0.0 : ((t - a.hour) / span).clamp(0.0, 1.0);

    final top = _Lab.lerp(_toLab(a.top), _toLab(b.top), k);
    final bottom = _Lab.lerp(_toLab(a.bottom), _toLab(b.bottom), k);

    // La bande médiane : le milieu perceptuel, bombé en chroma et en clarté.
    final mid = _Lab.lerp(top, bottom, middleStop);
    final middle = _Lab.fromHueChroma(
      mid.hue,
      mid.chroma * _middleChromaBoost,
      mid.l + _middleLightnessLift,
    );

    return DayPalette(
      hour: t,
      top: _toColor(top),
      middle: _toColor(middle),
      bottom: _toColor(bottom),
      accent: _accentFor(top),
      label: k < 0.5 ? a.label : b.label,
    );
  }

  /// L'accent : la **teinte de l'heure**, assombrie jusqu'à être lisible.
  ///
  /// La couleur suit l'heure ; la lisibilité ne se négocie pas.
  ///
  /// ⚠️ La teinte vient du **haut** du dégradé, jamais du bas. Relevé le
  /// 2026-08-15 en construisant la maquette : vers 8 h le bas est presque gris,
  /// et **une teinte extraite d'un gris est instable** — l'accent y virait au
  /// vert sans raison. Le haut reste franc toute la journée.
  static Color _accentFor(_Lab top) {
    final hue = top.chroma < 1e-6 ? 0.0 : top.hue;
    // On part clair et on descend : la première valeur qui passe le seuil est
    // la plus lumineuse acceptable, donc la plus proche de la teinte voulue.
    for (var l = 0.70; l > 0.20; l -= 0.01) {
      final candidate = _toColor(_Lab.fromHueChroma(hue, _accentChroma, l));
      if (contrastRatio(candidate, const Color(0xFFFFFFFF)) >=
          accentMinContrast) {
        return candidate;
      }
    }
    return _toColor(_Lab.fromHueChroma(hue, _accentChroma, 0.20));
  }
}
