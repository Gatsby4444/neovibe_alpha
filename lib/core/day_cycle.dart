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
  ///
  /// ⚠️ **Réservée à la VERTICALE du dégradé** (la bande médiane). Elle ne doit
  /// plus servir à traverser le temps : elle coupe à travers le gris, c'est le
  /// défaut corrigé le 2026-08-15 — voir [lerpArcPair].
  static _Lab lerp(_Lab x, _Lab y, double t) =>
      _Lab(x.l + (y.l - x.l) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t);

  /// Interpole le HAUT et le BAS d'un dégradé **sans les laisser diverger**.
  ///
  /// ## D'où vient l'arc — l'acquis du 2026-08-15, à ne pas perdre
  ///
  /// *(Cette section documentait `lerpArc`, supprimée le 2026-08-16 : cette
  /// fonction-ci est devenue son unique appelante, donc son seul usage.)*
  ///
  /// La corde ([lerp]) est une ligne droite dans le plan (a, b) : elle **coupe à
  /// travers le centre de la roue**, c'est-à-dire à travers le gris. Quand deux
  /// palettes voisines ont des teintes opposées, le milieu du segment devient
  /// plus terne que ses DEUX extrémités — mesuré 0,043 entre Jungle (0,075) et
  /// Cotton Candy (0,146). Ces creux étaient une bonne moitié des « gradients
  /// ternes » relevés par Jay, et ils n'étaient dans **aucune** palette.
  ///
  /// L'arc — la teinte tourne, la chroma se lerpe — les supprime.
  /// **Adopté définitivement par Jay le 2026-08-15** après comparaison à l'œil
  /// (*« l'arc me va nickel »*). La corde ne sert plus qu'à la verticale.
  ///
  /// ## Le défaut que la PAIRE supprime, mesuré le 2026-08-16
  ///
  /// L'arc seul choisissait le chemin court **pour chaque bord
  /// indépendamment**. Quand
  /// les deux bords d'un dégradé demandent des sens opposés, ils s'écartent en
  /// cours de route : mesuré sur `Desert → Azuria`, à 6 h 53 le haut était à
  /// **311°** (magenta, arrivé par la gauche) et le bas à **139°** (vert, arrivé
  /// par la droite) — **172° d'écart**. La verticale du dégradé relie alors deux
  /// teintes quasi opposées, et la bande médiane tombe à une chroma de
  /// **0,009**, c'est-à-dire **sous le seuil du gris** ([_greyChroma]).
  ///
  /// ⚠️ **Ce n'était pas un défaut de palette.** Les deux bords restaient francs
  /// tout du long (chroma 0,16 en haut, 0,12-0,16 en bas) : le gris n'existait
  /// **dans aucune des deux couleurs**, il naissait de leur écartement. C'est le
  /// même genre de cause que les « gradients ternes » du 2026-08-15 — le chemin,
  /// pas les couleurs — d'un cran plus profond.
  ///
  /// ⚠️ Ce phénomène **était déjà constaté** le 2026-08-15 (voir le commentaire
  /// de la bande médiane dans [DayCycle.at] : *« le haut et le bas passent, à
  /// certaines heures, par 180° d'écart de teinte »*). Il avait été traité comme
  /// une donnée à contourner — la corde sur la verticale — au lieu d'une cause à
  /// supprimer. La corde reste juste et nécessaire pour la stabilité ; elle ne
  /// pouvait simplement rien contre deux bords qui divergent.
  ///
  /// ## La règle retenue : le haut MÈNE, le bas SUIT
  ///
  /// Le haut tourne par son arc court, comme avant. Le bas n'est plus interpolé
  /// pour lui-même : il se tient **à un écart du haut**, et c'est cet écart qui
  /// s'interpole (par son propre arc court) entre celui de la palette de départ
  /// et celui de la palette d'arrivée.
  ///
  /// L'écart des bornes est donc une **borne de l'écart en route** : le dégradé
  /// garde sa forme tout du long, et les deux bords **ne peuvent pas** diverger.
  /// Ce n'est pas un réglage, c'est une propriété de la formule.
  ///
  /// ⚠️ **Une première version choisissait « le sens commun le moins coûteux ».
  /// Elle était fausse**, et le test l'a dit tout de suite : deux rotations
  /// minuscules de signes opposés (le haut −10°, le bas +15° — c'est-à-dire deux
  /// bords qui ne bougent presque pas) déclenchaient un détour de 350° sur l'un
  /// des deux. Elle a fabriqué un gris là où il n'y en avait jamais eu
  /// (`Deep Forest → Nuit`, chroma 0,000). *Un critère sur le SIGNE traite une
  /// différence de 25° comme un désaccord ; ce qu'il fallait regarder, c'est
  /// l'ÉCART, pas le sens.*
  static (_Lab, _Lab) lerpArcPair(
    _Lab xTop,
    _Lab yTop,
    _Lab xBot,
    _Lab yBot,
    double t,
  ) {
    final dTop = _short(yTop.hue - xTop.hue);

    // L'écart bas-haut à chaque bout, puis son interpolation.
    final gapStart = _short(xBot.hue - xTop.hue);
    final gapEnd = _short(yBot.hue - yTop.hue);
    final gap = gapStart + _short(gapEnd - gapStart) * t;

    final topHue = xTop.hue + dTop * t;
    return (
      _lerpAlong(xTop, yTop, topHue, t),
      _lerpAlong(xBot, yBot, topHue + gap, t),
    );
  }

  /// Ramène un écart d'angle dans ]-π, π] — l'arc court.
  static double _short(double d) {
    var v = d;
    while (v > math.pi) {
      v -= 2 * math.pi;
    }
    while (v < -math.pi) {
      v += 2 * math.pi;
    }
    return v;
  }

  /// Clarté et chroma se lerpent ; la **teinte est imposée** par l'appelant.
  ///
  /// Le garde-fou du quasi-gris reste ici : sous [_greyChroma] la teinte n'est
  /// qu'un bruit d'arrondi, et la faire tourner ferait pivoter une couleur qui
  /// n'en a pas.
  static _Lab _lerpAlong(_Lab x, _Lab y, double hue, double t) {
    final l = x.l + (y.l - x.l) * t;
    final c = x.chroma + (y.chroma - x.chroma) * t;
    final double h;
    if (x.chroma < _greyChroma) {
      h = y.hue;
    } else if (y.chroma < _greyChroma) {
      h = x.hue;
    } else {
      h = hue;
    }
    return fromHueChroma(h, c, l);
  }

  /// En dessous, une couleur n'a plus de teinte exploitable.
  static const _greyChroma = 0.012;

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

/// La même distance que [perceptualDistance], entre deux couleurs **déjà en
/// OkLab** — pour mesurer un chemin sans repasser par sRVB à chaque pas (ce qui
/// arrondirait sur 8 bits et fausserait la somme).
double _labDistance(_Lab x, _Lab y) {
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

  /// Une palette **sans heure** — un élément d'ORDRE, pas de calendrier.
  ///
  /// C'est la forme sous laquelle on déclare un jeu de couleurs : les heures
  /// sont ensuite calculées par [DayCycle.autoSchedule]. Le constructeur existe
  /// pour rendre la règle **structurelle** plutôt que documentaire — on ne peut
  /// pas poser une heure à la main là où le moteur doit la déduire (voir
  /// `RAPPELS.md` #29 ② : un segment trop rapide est un défaut que le test a
  /// déjà attrapé deux fois, et que personne ne verrait sur un ordre composé à
  /// la main).
  const DayAnchor.palette(this.top, this.bottom, this.label) : hour = 0;

  /// Heure locale, 0–24. **Nulle et sans signification** sur un ancrage construit
  /// par [DayAnchor.palette] : elle n'a de sens qu'après [DayCycle.autoSchedule].
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
  /// **L'ORDRE choisi par Jay le 2026-08-16**, dans l'écran d'aperçu.
  ///
  /// ⚠️ **Aucune heure n'est écrite ici, et c'est volontaire.** Jay a fourni sa
  /// palette accompagnée d'heures (0,00 · 1,41 · 1,86 · 5,32 …) — mais ces
  /// heures sont une **sortie** de [autoSchedule], pas un choix. Les recopier en
  /// dur aurait figé un résultat calculé : à la première retouche d'une couleur,
  /// elles seraient devenues fausses **sans que rien ne le signale**, et le
  /// partage « l'utilisateur pose l'ordre, le moteur déduit les heures »
  /// (`RAPPELS.md` #29 ②) aurait été rompu du côté où il compte le plus — le
  /// défaut par défaut.
  ///
  /// Le type l'impose désormais : [DayAnchor.palette] n'accepte pas d'heure.
  ///
  /// **Changements de Jay par rapport à l'ordre du 2026-08-15** : Azuria remonte
  /// de la 8ᵉ à la 5ᵉ place (juste après Desert), et Muted Olive Sky descend en
  /// dernier, derrière Cotton Candy et Lavender Dusk.
  static const _order = <DayAnchor>[
    DayAnchor.palette(Color(0xFF034C36), Color(0xFF003332), 'Deep Forest'),
    DayAnchor.palette(Color(0xFF04150F), Color(0xFF06231D), 'Nuit'),
    DayAnchor.palette(Color(0xFF071512), Color(0xFF0C342C), 'Jungle sombre'),
    DayAnchor.palette(Color(0xFFBC430D), Color(0xFFF09410), 'Desert'),
    DayAnchor.palette(Color(0xFF292F91), Color(0xFF4CA8DD), 'Azuria'),
    DayAnchor.palette(Color(0xFF1B0B3D), Color(0xFF5B22C8), 'Deep Ocean'),
    DayAnchor.palette(Color(0xFFA92655), Color(0xFFFD8D67), 'Velvet Sunset'),
    DayAnchor.palette(Color(0xFFDD7A83), Color(0xFFE8BFC3), 'Blush Silk'),
    DayAnchor.palette(Color(0xFF076653), Color(0xFFE2FBCE), 'Jungle'),
    DayAnchor.palette(Color(0xFF7AABFF), Color(0xFFFF9AEF), 'Cotton Candy'),
    DayAnchor.palette(Color(0xFF6968A6), Color(0xFFCF9893), 'Lavender Dusk'),
    DayAnchor.palette(Color(0xFF708F96), Color(0xFFAA895F), 'Muted Olive Sky'),
  ];

  /// Le calendrier effectif : l'ordre de Jay, dont les heures sont réparties au
  /// prorata de la distance de couleur.
  ///
  /// ⚠️ **C'est [_order] qu'on édite pour changer les couleurs, jamais ceci.**
  /// Les heures ne sont plus une donnée : elles sont **dérivées**, donc toujours
  /// cohérentes avec les couleurs en place. La cadence n'est pas uniforme et
  /// c'est le sujet — un grand écart de couleur reçoit beaucoup d'heures, un
  /// petit peu — de sorte qu'aucun segment ne peut être « le plus rapide ».
  ///
  /// ⚠️ La mise en garde de la version précédente (« le saut Jungle sombre →
  /// Desert a besoin de 2 h 30, ne pas le resserrer ») **n'a plus lieu d'être** :
  /// c'était un réglage à la main, et c'est précisément ce que la répartition au
  /// prorata rend impossible à rater. Le test des 1440 minutes reste le juge.
  static final anchors = autoSchedule(_order);

  /// Les **12 palettes distinctes**, sans l'ancrage de bouclage à 24 h.
  ///
  /// C'est ce qu'on réordonne : le dernier ancrage de [anchors] n'est pas une
  /// palette, c'est une répétition de la première pour fermer la boucle.
  static List<DayAnchor> get palettes => anchors.sublist(0, anchors.length - 1);

  /// Répartit les heures d'un ordre de palettes **proportionnellement à la
  /// distance de couleur** de chaque segment.
  ///
  /// ### Ce que ça garantit, et pourquoi ça règle un problème ouvert
  ///
  /// Répartir au prorata de la distance donne une **vitesse perçue uniforme** :
  /// un grand écart reçoit beaucoup d'heures, un petit écart peu. Aucun segment
  /// ne peut donc être « le plus rapide » — ils le sont tous autant.
  ///
  /// Conséquence directe : **n'importe quel ordre passe le test des 1440
  /// minutes**, sans arbitrage à la main. La journée demande ~3,8 ΔE de
  /// parcours total ; étalés sur 24 h cela fait 0,16 ΔE/h, soit 0,008 sur une
  /// session de 3 minutes — pour un seuil de 0,02. Il reste un facteur 2,5.
  ///
  /// C'était le point resté ouvert de `RAPPELS.md` #29 ② : *« le test ne
  /// protège plus un arrangement fait par l'utilisateur »*. Il le protège de
  /// nouveau, parce que ce n'est plus l'utilisateur qui pose les heures — il
  /// pose l'**ordre**, et le moteur en déduit la cadence.
  ///
  /// ⚠️ Seules les distances **relatives** comptent (c'est une proportion) :
  /// inutile de chercher une métrique exacte au ΔE près. On prend le pire des
  /// deux bords ; la bande médiane en est dérivée et suit le même facteur.
  ///
  /// ⚠️ **Les deux sorties dégénérées ci-dessous rendaient `anchors`** — ce qui
  /// est devenu une **référence circulaire** le 2026-08-16, `anchors` étant
  /// désormais produit par cette fonction. Dart ne l'aurait signalé qu'à
  /// l'exécution, et seulement sur une entrée qui n'arrive jamais. Elles rendent
  /// donc l'entrée telle quelle : c'est aussi la réponse honnête, il n'y a rien
  /// à répartir sur moins de deux palettes.
  static List<DayAnchor> autoSchedule(List<DayAnchor> order) {
    if (order.length < 2) return List.of(order);

    // ⚠️ **La LONGUEUR DU CHEMIN, pas la distance à vol d'oiseau** (corrigé le
    // 2026-08-16). Cette fonction mesurait `perceptualDistance`, c'est-à-dire la
    // corde — alors que le moteur parcourt un ARC depuis le 2026-08-15. Un
    // segment qui fait tourner la teinte de 200° parcourt bien plus de chemin
    // que la corde entre ses deux bouts : il recevait donc trop peu d'heures, et
    // défilait plus vite que les autres.
    //
    // L'incohérence était **latente depuis l'adoption de l'arc** ; elle n'a
    // sauté aux yeux qu'en couplant les deux bords, qui allonge encore le
    // trajet. Elle vide de son sens l'énoncé « la vitesse perçue est uniforme »,
    // qui est la raison d'être de toute cette répartition.
    //
    // On échantillonne le trajet réel au lieu de chercher une formule fermée :
    // la longueur d'arc en OkLab n'en a pas de simple, et 24 pas suffisent
    // largement (calculé une fois au démarrage, pour 12 segments).
    double gap(DayAnchor a, DayAnchor b) {
      const steps = 24;
      final xTop = _toLab(a.top);
      final yTop = _toLab(b.top);
      final xBot = _toLab(a.bottom);
      final yBot = _toLab(b.bottom);
      var top = 0.0;
      var bottom = 0.0;
      var prev = _Lab.lerpArcPair(xTop, yTop, xBot, yBot, 0);
      for (var i = 1; i <= steps; i++) {
        final cur = _Lab.lerpArcPair(xTop, yTop, xBot, yBot, i / steps);
        top += _labDistance(prev.$1, cur.$1);
        bottom += _labDistance(prev.$2, cur.$2);
        prev = cur;
      }
      return math.max(top, bottom);
    }

    // Le segment de bouclage (dernier → premier) compte comme les autres :
    // minuit n'est pas un bord, c'est un point de passage.
    final gaps = <double>[
      for (var i = 0; i < order.length; i++)
        gap(order[i], order[(i + 1) % order.length]),
    ];
    final total = gaps.reduce((a, b) => a + b);
    if (total <= 0) return List.of(order);

    final out = <DayAnchor>[];
    var hour = 0.0;
    for (var i = 0; i < order.length; i++) {
      final a = order[i];
      out.add(DayAnchor(hour, a.top, a.bottom, a.label));
      hour += 24 * gaps[i] / total;
    }
    // Fermeture : la première palette réapparaît à 24 h, sinon `at` n'aurait
    // pas de segment pour la fin de journée.
    out.add(
      DayAnchor(24, order.first.top, order.first.bottom, order.first.label),
    );
    return out;
  }

  /// La pire dérive sur une session de 3 minutes, pour un calendrier donné.
  ///
  /// Le même énoncé que `test/day_cycle_test.dart`, rendu disponible à
  /// l'exécution : l'écran d'aperçu peut ainsi dire à Jay si l'ordre qu'il
  /// vient de composer tient — sans quoi « on peut tout réordonner » serait une
  /// promesse qu'on ne sait pas vérifier.
  static double worstSessionDrift(List<DayAnchor> schedule) {
    var worst = 0.0;
    for (var m = 0; m < 1440; m++) {
      final a = at(m / 60, schedule: schedule);
      final b = at((m + 3) / 60, schedule: schedule);
      final d = math.max(
        perceptualDistance(a.top, b.top),
        math.max(
          perceptualDistance(a.middle, b.middle),
          perceptualDistance(a.bottom, b.bottom),
        ),
      );
      if (d > worst) worst = d;
    }
    return worst;
  }

  /// Le seuil du juste-perceptible, côte à côte, en OkLab.
  static const justNoticeable = 0.02;

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
  /// [schedule] permet d'essayer un **autre ordre** que celui de l'app — c'est
  /// ce dont se sert l'écran d'aperçu. Il reste `null` partout ailleurs : le
  /// thème ne se règle pas depuis un appelant, il se règle dans [anchors].
  static DayPalette at(double hours, {List<DayAnchor>? schedule}) {
    final table = schedule ?? anchors;
    final t = hours % 24;
    var i = 0;
    while (i < table.length - 2 && table[i + 1].hour <= t) {
      i++;
    }
    final a = table[i];
    final b = table[i + 1];
    final span = b.hour - a.hour;
    final k = span <= 0 ? 0.0 : ((t - a.hour) / span).clamp(0.0, 1.0);

    // Les deux bords tournent ENSEMBLE — voir `_Lab.lerpArcPair`. Les
    // interpoler séparément les laissait diverger jusqu'à 172°, et la bande
    // médiane tombait alors sous le seuil du gris.
    final (top, bottom) = _Lab.lerpArcPair(
      _toLab(a.top),
      _toLab(b.top),
      _toLab(a.bottom),
      _toLab(b.bottom),
      k,
    );

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
