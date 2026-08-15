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

  /// Interpolation **par la corde** : la ligne droite dans le plan (a, b).
  static _Lab lerp(_Lab x, _Lab y, double t) =>
      _Lab(x.l + (y.l - x.l) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t);

  /// Interpolation **par l'arc** : la teinte tourne, la chroma se lerpe.
  ///
  /// C'est le correctif du 2026-08-15. La corde ci-dessus est une ligne droite
  /// dans le plan (a, b) — donc elle **coupe à travers le centre de la roue**,
  /// c'est-à-dire à travers le gris. Quand deux palettes voisines ont des
  /// teintes opposées, le milieu du segment est plus terne que ses DEUX
  /// extrémités : mesuré 0,043 entre Jungle (0,075) et Cotton Candy (0,146).
  ///
  /// Ces creux sont une bonne moitié des « gradients ternes » relevés par Jay,
  /// et ils ne sont dans **aucune** palette — ils naissent du chemin.
  ///
  /// ⚠️ Le garde-fou du quasi-gris n'est pas cosmétique : sous une chroma de
  /// ~0,012 la teinte n'est plus qu'un bruit d'arrondi, et la faire tourner
  /// ferait pivoter une couleur qui n'en a pas.
  static _Lab lerpArc(_Lab x, _Lab y, double t) {
    final l = x.l + (y.l - x.l) * t;
    final c = x.chroma + (y.chroma - x.chroma) * t;

    // L'arc COURT : sans ce repliement on ferait le tour par le long côté.
    var dh = y.hue - x.hue;
    while (dh > math.pi) {
      dh -= 2 * math.pi;
    }
    while (dh < -math.pi) {
      dh += 2 * math.pi;
    }

    final double hue;
    if (x.chroma < _greyChroma) {
      hue = y.hue;
    } else if (y.chroma < _greyChroma) {
      hue = x.hue;
    } else {
      hue = x.hue + dh * t;
    }
    return fromHueChroma(hue, c, l);
  }

  /// En dessous, une couleur n'a plus de teinte exploitable.
  static const _greyChroma = 0.012;

  static _Lab fromHueChroma(double hue, double chroma, double lightness) =>
      _Lab(lightness, chroma * math.cos(hue), chroma * math.sin(hue));
}

/// Le chemin suivi par la couleur entre deux ancrages.
///
/// Les deux sont livrés le temps que Jay tranche à l'œil (écran d'aperçu →
/// « Chemin »). **Une fois son choix fait, l'autre doit disparaître** — garder
/// une variante non retenue, c'est garder du code que personne ne relit.
enum HuePath {
  /// La ligne droite dans le plan (a, b). Coupe à travers le gris.
  chord('Corde'),

  /// La teinte tourne sur l'arc court. Garde la couleur franche.
  arc('Arc');

  const HuePath(this.label);
  final String label;
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

/// **Chroma** perceptuelle d'une couleur : sa distance à l'axe des gris.
///
/// C'est la mesure de « à quel point c'est coloré », indépendamment de la
/// clarté — donc l'énoncé chiffré de « ce gradient est terne ».
double chromaOf(Color c) => _toLab(c).chroma;

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
    required this.from,
    required this.to,
    required this.blend,
  });

  final double hour;

  /// Les **trois** arrêts du fond, de haut en bas.
  final Color top;
  final Color middle;
  final Color bottom;

  /// Couleur d'action, garantie lisible sous du texte blanc.
  final Color accent;

  /// L'ancrage d'où l'on vient et celui vers lequel on va.
  final String from;
  final String to;

  /// Avancement entre les deux, 0 = exactement [from], 1 = exactement [to].
  final double blend;

  /// Ce qui est affiché **à l'instant même**, nommé sans mentir.
  ///
  /// Demandé par Jay le 2026-08-15 : *« ajoute un indicateur du thème actuel
  /// en direct de ce qui est affiché, que je sache de quoi je parle
  /// exactement »*.
  ///
  /// ⚠️ La version précédente n'affichait que l'ancrage **le plus proche**.
  /// C'était trompeur au milieu d'un segment : au moment exact où la couleur
  /// n'est celle d'aucune palette, l'écran en nommait une. Or c'est précisément
  /// là que se trouvent les creux ternes — donc l'endroit où un nom juste
  /// compte le plus.
  String get description {
    if (blend <= 0.03) return from;
    if (blend >= 0.97) return to;
    return '$from → $to · ${(blend * 100).round()} %';
  }
}

/// Le cycle.
abstract final class DayCycle {
  /// Les ancrages, triés par heure.
  ///
  /// **Version 3, 2026-08-15.** Réorganisée selon l'**audience réelle** de
  /// chaque heure, et non selon le réalisme du ciel — demande de Jay :
  /// *« certains gradients sont ternes, et les plus colorés sont parfois mis
  /// la nuit pendant que personne ne regarde »*.
  ///
  /// ### Ce que la v2 avait de faux, mesuré
  ///
  /// Une **anti-corrélation quasi parfaite** entre chroma et audience : les
  /// deux palettes les plus colorées (Deep Ocean 0,159 · Velvet Sunset 0,157)
  /// étaient à 4 h et 6 h, quand plus personne ne regarde ; et le pic du soir
  /// (19 h–22 h) tombait sur les trois plus ternes — Lavender Dusk 0,081,
  /// Deep Forest 0,063, Nuit 0,032.
  ///
  /// ### Les deux décisions de Jay portées ici
  ///
  /// 1. **Tout est décalé d'environ 2 h** — le cluster coloré passe de 3 h-6 h
  ///    (audience 0,04) à 6 h-10 h (audience 0,15 à 0,6).
  /// 2. **Desert quitte le soir pour la nuit**, juste après le vert sombre et
  ///    avant Deep Ocean : *« c'est un peu sombre pour l'après-midi et ne
  ///    s'insère pas bien là où c'est actuellement »*.
  ///
  /// ⚠️ **Contrepartie assumée, mesurée, à ne pas oublier** : Desert est la
  /// palette la plus colorée de l'arc (0,164) **et** la seule qui soit à la
  /// fois riche, chaude et mi-sombre — donc la seule qui cochait tout pour le
  /// pic du soir. En la mettant à 6 h, plus rien dans le jeu ne tient ce rôle,
  /// et le pic plafonne autour de 0,06-0,12. C'est un arbitrage de cohérence
  /// d'arc contre un arbitrage d'audience ; Jay a tranché pour le premier.
  ///
  /// Bilan : chroma moyenne **réellement vue** 0,0771 → **0,1031** (+34 %),
  /// avec l'arc de teinte.
  ///
  /// ⚠️ **C'est le seul endroit à éditer pour changer les couleurs.** Le moteur
  /// ne bouge pas quand la palette bouge — et le test des 1440 minutes dit
  /// immédiatement si un nouvel ancrage casse la lisibilité.
  static const anchors = <DayAnchor>[
    // ⚠️ La cadence n'est plus uniforme, et c'est le sujet même de cette
    // version : chaque segment reçoit la durée que sa distance de couleur
    // exige, et le reste du budget va là où il y a du monde.
    //
    // Mesuré : le minimum imposé par le seuil d'imperceptibilité est de ~11 h
    // sur 24 — il reste donc 13 h à répartir librement. La nuit morte
    // (1 h-6 h) absorbe les segments longs et ternes ; les heures d'usage
    // reçoivent les palettes franches.
    //
    // ⚠️ Le saut `Jungle sombre → Desert` (vert quasi noir → orange) est le
    // plus grand de l'arc : à 1 h 30 il FAISAIT ÉCHOUER le test (0,0202 pour
    // un seuil de 0,0200). Il lui faut 2 h 30. Ne pas le resserrer.
    DayAnchor(0.0, Color(0xFF034C36), Color(0xFF003332), 'Deep Forest'),
    DayAnchor(1.5, Color(0xFF04150F), Color(0xFF06231D), 'Nuit'),
    DayAnchor(3.5, Color(0xFF071512), Color(0xFF0C342C), 'Jungle sombre'),
    DayAnchor(6.0, Color(0xFFBC430D), Color(0xFFF09410), 'Desert'),
    DayAnchor(8.0, Color(0xFF1B0B3D), Color(0xFF5B22C8), 'Deep Ocean'),
    DayAnchor(10.0, Color(0xFFA92655), Color(0xFFFD8D67), 'Velvet Sunset'),
    DayAnchor(11.5, Color(0xFFDD7A83), Color(0xFFE8BFC3), 'Blush Silk'),
    DayAnchor(13.0, Color(0xFF292F91), Color(0xFF4CA8DD), 'Azuria'),
    DayAnchor(14.5, Color(0xFF076653), Color(0xFFE2FBCE), 'Jungle'),
    DayAnchor(16.0, Color(0xFF708F96), Color(0xFFAA895F), 'Muted Olive Sky'),
    DayAnchor(18.0, Color(0xFF7AABFF), Color(0xFFFF9AEF), 'Cotton Candy'),
    DayAnchor(21.5, Color(0xFF6968A6), Color(0xFFCF9893), 'Lavender Dusk'),
    DayAnchor(24.0, Color(0xFF034C36), Color(0xFF003332), 'Deep Forest'),
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
  ///
  /// [hue] choisit le chemin suivi **dans le temps**, d'un ancrage au suivant.
  static DayPalette at(double hours, {HuePath hue = HuePath.arc}) {
    final t = hours % 24;
    var i = 0;
    while (i < anchors.length - 2 && anchors[i + 1].hour <= t) {
      i++;
    }
    final a = anchors[i];
    final b = anchors[i + 1];
    final span = b.hour - a.hour;
    final k = span <= 0 ? 0.0 : ((t - a.hour) / span).clamp(0.0, 1.0);

    final lerp = hue == HuePath.arc ? _Lab.lerpArc : _Lab.lerp;
    final top = lerp(_toLab(a.top), _toLab(b.top), k);
    final bottom = lerp(_toLab(a.bottom), _toLab(b.bottom), k);

    // La bande médiane : le milieu perceptuel, bombé en chroma et en clarté.
    //
    // ⚠️ **Toujours par la CORDE, jamais par l'arc**, et ce n'est pas un
    // oubli. Relevé le 2026-08-15 : le haut et le bas d'un même dégradé
    // passent, à certaines heures, par 180° d'écart de teinte. L'arc court
    // bascule alors de côté d'un instant à l'autre, et la bande médiane saute
    // à travers la roue — mesuré ΔE 0,29 sur 3 minutes, **quinze fois** le
    // seuil, là où la corde donne 0,017.
    //
    // La distinction à garder : l'arc sert à traverser le TEMPS (deux palettes
    // choisies, dont on veut le chemin franc) ; la corde sert la VERTICALE du
    // dégradé, que le moteur de rendu interpolera de toute façon en ligne
    // droite entre les arrêts.
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
      from: a.label,
      to: b.label,
      blend: k,
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
