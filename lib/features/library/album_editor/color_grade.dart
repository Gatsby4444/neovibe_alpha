import 'dart:math' as math;

/// Les réglages de couleur d'un média, et leur traduction en **une matrice
/// 4×5** — celle de `ColorFilter.matrix`.
///
/// ### Pourquoi une matrice, et un shader
///
/// Une partie des réglages est **linéaire** (luminosité, contraste,
/// saturation, chaleur, teinte, fondu) : c'est une matrice 4×5, la même pour
/// tout le monde. L'autre partie ne l'est pas (ombres, hautes lumières,
/// netteté, vignette) : elle vit dans **un shader**, écrit deux fois avec la
/// même formule — `shaders/album_grade.frag` pour Flutter (aperçu et export
/// photo) et `MediaTranscoder.kt` pour la vidéo. [toUniforms] est le contrat
/// entre les deux : la liste des nombres, dans un ordre fixé ici.
///
/// Ce qu'on voit est ce qu'on publie, et il n'y a qu'une seule définition de
/// « +20 % de contraste » dans l'app.
///
/// Tout est **pur** : pas de widget, pas de fichier, pas de natif. Les tests
/// vérifient la matrice et les nombres, pas des pixels.
class ColorGrade {
  const ColorGrade({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.tint = 0,
    this.fade = 0,
    this.vignette = 0,
    this.shadows = 0,
    this.highlights = 0,
    this.sharpen = 0,
    this.lux = 0,
  });

  static const none = ColorGrade();

  /// −1 … +1 : plus sombre / plus clair.
  final double brightness;

  /// −1 … +1 : plus plat / plus contrasté.
  final double contrast;

  /// −1 … +1 : −1 = noir et blanc, +1 = couleurs doublées.
  final double saturation;

  /// −1 … +1 : plus froid (bleu) / plus chaud (orange).
  final double warmth;

  /// −1 … +1 : plus vert / plus magenta.
  final double tint;

  /// 0 … 1 : les noirs remontent vers le gris (l'effet « pellicule »).
  final double fade;

  /// 0 … 1 : les bords s'assombrissent (un voile radial, dans le shader).
  final double vignette;

  /// −1 … +1 : les zones sombres remontent (+) ou s'enfoncent (−).
  final double shadows;

  /// −1 … +1 : les zones claires s'éclairent (+) ou se retiennent (−).
  final double highlights;

  /// 0 … 1 : netteté (un masque flou soustrait, dans le shader).
  final double sharpen;

  /// 0 … 1 : « Lux », le coup de peps automatique d'Instagram — chez nous un
  /// mélange fixe de contraste, d'ombres relevées et d'un peu de saturation,
  /// **replié dans les autres réglages** par [resolved]. Il n'atteint jamais
  /// le shader tel quel.
  final double lux;

  ColorGrade copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
    double? tint,
    double? fade,
    double? vignette,
    double? shadows,
    double? highlights,
    double? sharpen,
    double? lux,
  }) => ColorGrade(
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    warmth: warmth ?? this.warmth,
    tint: tint ?? this.tint,
    fade: fade ?? this.fade,
    vignette: vignette ?? this.vignette,
    shadows: shadows ?? this.shadows,
    highlights: highlights ?? this.highlights,
    sharpen: sharpen ?? this.sharpen,
    lux: lux ?? this.lux,
  );

  /// Ce réglage posé PAR-DESSUS [base] (un filtre) : les valeurs s'ajoutent,
  /// bornées. C'est ainsi qu'un utilisateur retouche un filtre sans le perdre.
  ColorGrade over(ColorGrade base) => ColorGrade(
    brightness: _c1(base.brightness + brightness),
    contrast: _c1(base.contrast + contrast),
    saturation: _c1(base.saturation + saturation),
    warmth: _c1(base.warmth + warmth),
    tint: _c1(base.tint + tint),
    fade: _c01(base.fade + fade),
    vignette: _c01(base.vignette + vignette),
    shadows: _c1(base.shadows + shadows),
    highlights: _c1(base.highlights + highlights),
    sharpen: _c01(base.sharpen + sharpen),
    lux: _c01(base.lux + lux),
  );

  /// Ce réglage à [k] de son intensité (0 = rien, 1 = entier) : l'intensité
  /// d'un filtre, comme sur Instagram.
  ColorGrade scaled(double k) {
    final f = k.clamp(0.0, 1.0);
    return ColorGrade(
      brightness: brightness * f,
      contrast: contrast * f,
      saturation: saturation * f,
      warmth: warmth * f,
      tint: tint * f,
      fade: fade * f,
      vignette: vignette * f,
      shadows: shadows * f,
      highlights: highlights * f,
      sharpen: sharpen * f,
      lux: lux * f,
    );
  }

  /// Le réglage avec « Lux » replié dans les autres : c'est celui que la
  /// matrice et le shader lisent.
  ColorGrade get resolved => lux == 0
      ? this
      : ColorGrade(
          brightness: brightness,
          contrast: _c1(contrast + 0.25 * lux),
          saturation: _c1(saturation + 0.1 * lux),
          warmth: warmth,
          tint: tint,
          fade: fade,
          vignette: vignette,
          shadows: _c1(shadows + 0.2 * lux),
          highlights: _c1(highlights - 0.1 * lux),
          sharpen: _c01(sharpen + 0.15 * lux),
        );

  bool get isIdentity =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      warmth == 0 &&
      tint == 0 &&
      fade == 0 &&
      vignette == 0 &&
      shadows == 0 &&
      highlights == 0 &&
      sharpen == 0 &&
      lux == 0;

  /// **Le contrat des shaders** : les nombres que le shader Flutter et le
  /// shader GL reçoivent, dans cet ordre — la matrice 4×4 (colonnes), les
  /// quatre offsets en 0..1, puis ombres, hautes lumières, netteté, vignette.
  /// 24 valeurs. Changer cet ordre, c'est changer les deux shaders.
  List<double> toUniforms() {
    final r = resolved;
    final m = r.toMatrix();
    return [
      // mat4, colonne par colonne : la colonne j porte les coefficients du
      // canal d'entrée j pour les quatre canaux de sortie.
      m[0], m[5], m[10], m[15], //
      m[1], m[6], m[11], m[16], //
      m[2], m[7], m[12], m[17], //
      m[3], m[8], m[13], m[18], //
      m[4] / 255, m[9] / 255, m[14] / 255, m[19] / 255, //
      r.shadows, r.highlights, r.sharpen, r.vignette,
    ];
  }

  static const uniformCount = 24;

  /// La matrice 4×5, ligne par ligne, telle que `ColorFilter.matrix` la lit :
  /// `R' = a·R + b·G + c·B + d·A + e`, avec `e` en unités de 0 à 255.
  ///
  /// Ordre d'application (de la première à la dernière) : saturation →
  /// contraste → luminosité → chaleur / teinte → fondu. L'ordre compte peu
  /// pour des réglages modestes, mais il est **fixé** : le shader natif suit
  /// exactement le même.
  List<double> toMatrix() {
    final g = resolved;
    var m = _identity();
    m = _mul(_saturationMatrix(1 + g.saturation), m);
    // Contraste : autour du gris moyen. s ∈ [0,2 ; 1,8].
    final s = 1 + g.contrast * 0.8;
    m = _mul(_scaleOffset(s, 128 * (1 - s)), m);
    // Luminosité : un décalage, ±40 % de la plage au maximum.
    m = _mul(_scaleOffset(1, g.brightness * 102), m);
    // Chaleur : rouge et bleu en sens inverse. Teinte : vert contre magenta.
    m = _mul(
      _offsets(
        r: warmth * 26 + tint * 10,
        g: -tint * 20,
        b: -warmth * 26 + tint * 10,
      ),
      m,
    );
    // Fondu : les noirs remontent, la plage se tasse un peu.
    if (fade > 0) {
      m = _mul(_scaleOffset(1 - fade * 0.25, fade * 64), m);
    }
    return m.sublist(0, 20);
  }

  static double _c1(double v) => v.clamp(-1.0, 1.0);
  static double _c01(double v) => v.clamp(0.0, 1.0);

  // ── Algèbre 5×5 (la dernière ligne est toujours 0 0 0 0 1) ────────────

  static List<double> _identity() => [
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
    0, 0, 0, 0, 1, //
  ];

  static List<double> _scaleOffset(double s, double o) => [
    s, 0, 0, 0, o, //
    0, s, 0, 0, o, //
    0, 0, s, 0, o, //
    0, 0, 0, 1, 0, //
    0, 0, 0, 0, 1, //
  ];

  static List<double> _offsets({
    required double r,
    required double g,
    required double b,
  }) => [
    1, 0, 0, 0, r, //
    0, 1, 0, 0, g, //
    0, 0, 1, 0, b, //
    0, 0, 0, 1, 0, //
    0, 0, 0, 0, 1, //
  ];

  /// Poids de luminance Rec. 709 — ceux qu'utilise Skia pour la saturation.
  static const _lr = 0.2126;
  static const _lg = 0.7152;
  static const _lb = 0.0722;

  static List<double> _saturationMatrix(double f) {
    final ir = (1 - f) * _lr;
    final ig = (1 - f) * _lg;
    final ib = (1 - f) * _lb;
    return [
      ir + f, ig, ib, 0, 0, //
      ir, ig + f, ib, 0, 0, //
      ir, ig, ib + f, 0, 0, //
      0, 0, 0, 1, 0, //
      0, 0, 0, 0, 1, //
    ];
  }

  /// `a × b` (a appliquée APRÈS b).
  static List<double> _mul(List<double> a, List<double> b) {
    final out = List<double>.filled(25, 0);
    for (var r = 0; r < 5; r++) {
      for (var c = 0; c < 5; c++) {
        var v = 0.0;
        for (var k = 0; k < 5; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        out[r * 5 + c] = v;
      }
    }
    return out;
  }

  /// Applique la matrice à une couleur (0..255 par canal), pour les tests et
  /// pour l'aperçu des puces de filtres. Bornée comme le fait le GPU.
  static (double, double, double) apply(
    List<double> m,
    double r,
    double g,
    double b,
  ) {
    double row(int i) =>
        (m[i * 5] * r + m[i * 5 + 1] * g + m[i * 5 + 2] * b + m[i * 5 + 4])
            .clamp(0, 255)
            .toDouble();
    return (row(0), row(1), row(2));
  }

  @override
  bool operator ==(Object other) =>
      other is ColorGrade &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.warmth == warmth &&
      other.tint == tint &&
      other.fade == fade &&
      other.vignette == vignette &&
      other.shadows == shadows &&
      other.highlights == highlights &&
      other.sharpen == sharpen &&
      other.lux == lux;

  @override
  int get hashCode => Object.hash(
    brightness,
    contrast,
    saturation,
    warmth,
    tint,
    fade,
    vignette,
    shadows,
    highlights,
    sharpen,
    lux,
  );

  @override
  String toString() =>
      'ColorGrade(b=$brightness c=$contrast s=$saturation w=$warmth '
      't=$tint f=$fade v=$vignette sh=$shadows hl=$highlights n=$sharpen '
      'lux=$lux)';
}

/// Les filtres nommés — des réglages tout faits, dans l'esprit de ceux
/// d'Instagram. Chacun n'est **qu'un [ColorGrade]** : l'utilisateur peut
/// ensuite le retoucher, et l'export n'a qu'une matrice à appliquer.
enum AlbumFilter {
  normal('Normal', ColorGrade.none),
  clarendon(
    'Clarendon',
    ColorGrade(
      contrast: 0.2,
      saturation: 0.35,
      brightness: 0.05,
      warmth: -0.05,
    ),
  ),
  gingham('Gingham', ColorGrade(fade: 0.35, saturation: -0.15, warmth: -0.05)),
  moon('Moon', ColorGrade(saturation: -1, contrast: 0.1, brightness: 0.1)),
  lark('Lark', ColorGrade(brightness: 0.1, saturation: 0.1, warmth: -0.1)),
  reyes(
    'Reyes',
    ColorGrade(fade: 0.4, saturation: -0.25, warmth: 0.15, brightness: 0.1),
  ),
  juno('Juno', ColorGrade(saturation: 0.35, warmth: 0.1, contrast: 0.1)),
  slumber(
    'Slumber',
    ColorGrade(saturation: -0.35, brightness: -0.05, fade: 0.2, warmth: 0.15),
  ),
  crema('Crema', ColorGrade(saturation: -0.2, warmth: 0.1, fade: 0.15)),
  ludwig(
    'Ludwig',
    ColorGrade(saturation: -0.1, contrast: 0.1, brightness: 0.05, warmth: 0.05),
  ),
  aden(
    'Aden',
    ColorGrade(warmth: 0.2, saturation: -0.15, fade: 0.2, tint: 0.1),
  ),
  perpetua('Perpetua', ColorGrade(tint: -0.1, warmth: -0.1, contrast: 0.1)),
  valencia('Valencia', ColorGrade(warmth: 0.25, fade: 0.15, contrast: 0.05)),
  xpro(
    'X-Pro II',
    ColorGrade(contrast: 0.35, saturation: 0.3, vignette: 0.6, warmth: 0.1),
  ),
  lofi('Lo-Fi', ColorGrade(contrast: 0.45, saturation: 0.4)),
  willow('Willow', ColorGrade(saturation: -1, fade: 0.25, brightness: 0.05)),
  inkwell('Inkwell', ColorGrade(saturation: -1, contrast: 0.15)),
  nashville(
    'Nashville',
    ColorGrade(warmth: 0.3, fade: 0.3, saturation: 0.1, tint: 0.1),
  ),
  hudson(
    'Hudson',
    ColorGrade(warmth: -0.25, contrast: 0.1, brightness: 0.05, vignette: 0.3),
  );

  const AlbumFilter(this.label, this.grade);

  final String label;
  final ColorGrade grade;
}

/// Le voile de vignette : opacité au bord pour une valeur donnée, et le rayon
/// à partir duquel il commence — partagés par l'aperçu, l'export photo et le
/// shader vidéo.
abstract final class Vignette {
  /// Opacité du noir sur les coins (0 … 0,7).
  static double edgeAlpha(double v) => (v * 0.7).clamp(0.0, 0.7);

  /// Le voile commence à 45 % de la diagonale et est plein à 100 %.
  static const start = 0.45;

  /// L'opacité à une distance [d] du centre (0 = centre, 1 = coin), pour
  /// une vignette [v]. Fonction de référence des trois rendus.
  static double alphaAt(double d, double v) {
    if (v <= 0 || d <= start) return 0;
    final t = ((d - start) / (1 - start)).clamp(0.0, 1.0);
    // Une montée douce (smoothstep) : pas de bord visible.
    final s = t * t * (3 - 2 * t);
    return edgeAlpha(v) * s;
  }

  /// Distance normalisée d'un point (x, y ∈ 0..1) au centre, 1 au coin.
  static double distance(double x, double y) =>
      math.sqrt((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)) / math.sqrt(0.5);
}
