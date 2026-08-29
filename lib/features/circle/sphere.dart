import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

// La géométrie de la constellation — **une vraie sphère, et rien d'autre**.
//
// ---------------------------------------------------------------------------
// ## Pourquoi ce fichier existe, et ce qu'il remplace
//
// Les deux premières versions posaient les amis sur un **plan** qu'on
// déplaçait, avec un effet de loupe par-dessus. Jay l'a dit exactement :
// *« tout le groupe bouge en même temps »*. C'est la signature d'un plan : sur
// un plan, tous les points se déplacent du même vecteur.
//
// **Sur une sphère qui tourne, non.** Un point près de l'axe de rotation bouge
// à peine, un point sur l'équateur file. C'est ce qui donne le volume — et
// aucun réglage de courbe sur un plan ne peut l'imiter.
//
// ⚠️ Tout ce fichier est **pur** : ni widget, ni écran, ni état. C'est ce qui
// permet de le mesurer, et c'est ce que Jay demande quand il dit *« de vraies
// règles, pas du bricolage »*. Un effet visuel se juge à l'œil, mais ses
// invariants — rien ne grandit en s'éloignant, la rotation ne dérive pas, deux
// amis ne se superposent jamais — ne se voient pas et se démontrent.

/// Un point dans l'espace. Minuscule exprès.
///
/// ⚠️ **Écrit à la main plutôt que pris dans `vector_math`.** Ce paquet n'est
/// pas une dépendance déclarée du projet : l'importer marcherait aujourd'hui et
/// casserait le jour où Flutter cesse de l'entraîner. Neuf opérations ne valent
/// pas ce risque.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get longueur => math.sqrt(x * x + y * y + z * z);

  Vec3 get normalise {
    final l = longueur;
    // Un vecteur nul n'a pas de direction : on rend un axe arbitraire mais
    // valide plutôt que des `NaN` qui se propageraient dans toute la matrice.
    if (l == 0) return const Vec3(0, 1, 0);
    return Vec3(x / l, y / l, z / l);
  }

  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  @override
  bool operator ==(Object other) =>
      other is Vec3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, '
      '${z.toStringAsFixed(3)})';
}

/// Une rotation dans l'espace, comme matrice 3×3.
///
/// ## ⚠️ Elle se réorthonormalise — et voici la MESURE, pas la légende
///
/// Faire tourner une sphère, c'est multiplier des rotations les unes par les
/// autres, image après image. Chaque multiplication ajoute une miette d'erreur
/// d'arrondi. La sagesse populaire veut que la matrice cesse d'être une
/// rotation au bout d'un moment et que la sphère se déforme en œuf.
///
/// 🔴 **J'ai écrit exactement ça, et c'était FAUX** (corrigé le 2026-08-30
/// après un contre-test qui refusait de tomber). Mesuré, en `double` :
///
/// | Compositions | Sans remise d'équerre | Avec |
/// |---|---|---|
/// | 5 000 | 3,0 × 10⁻¹³ | 2,2 × 10⁻¹⁶ |
/// | 100 000 | 5,9 × 10⁻¹² | 2,2 × 10⁻¹⁶ |
/// | 1 000 000 *(≈ 4 h de rotation continue)* | 5,9 × 10⁻¹¹ | 2,2 × 10⁻¹⁶ |
///
/// Autrement dit : **la déformation n'arrive jamais** à cette précision. Le
/// mythe vient des matrices en simple précision, où il est bien réel.
///
/// ➡️ **La remise d'équerre est gardée quand même**, pour une raison qui tient
/// et une seule : elle transforme *« l'erreur est petite »* en *« il n'y a pas
/// d'erreur »*, pour une vingtaine d'opérations par image. Un invariant exact
/// vaut mieux qu'un invariant probable — mais il fallait le dire honnêtement.
///
/// ⚠️ **Et le test le prouve**, avec une tolérance à 10⁻¹⁴ : il tombe si on
/// retire la ligne. Un test dont la tolérance ne mord pas ne mesure rien.
class Rot {
  const Rot(this._m);

  /// Neuf coefficients, en lignes : m[0..2] est la première ligne.
  final List<double> _m;

  static const identite = Rot([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  /// La rotation d'un [angle] (radians) autour d'un [axe], par la formule de
  /// Rodrigues.
  factory Rot.axeAngle(Vec3 axe, double angle) {
    final u = axe.normalise;
    final c = math.cos(angle);
    final s = math.sin(angle);
    final t = 1 - c;
    return Rot([
      t * u.x * u.x + c, t * u.x * u.y - s * u.z, t * u.x * u.z + s * u.y, //
      t * u.x * u.y + s * u.z, t * u.y * u.y + c, t * u.y * u.z - s * u.x, //
      t * u.x * u.z - s * u.y, t * u.y * u.z + s * u.x, t * u.z * u.z + c, //
    ]);
  }

  Vec3 applique(Vec3 v) => Vec3(
    _m[0] * v.x + _m[1] * v.y + _m[2] * v.z,
    _m[3] * v.x + _m[4] * v.y + _m[5] * v.z,
    _m[6] * v.x + _m[7] * v.y + _m[8] * v.z,
  );

  /// `this ∘ autre` — on applique d'abord [autre], puis `this`.
  ///
  /// C'est l'ordre qui compte : un geste à l'écran s'ajoute **après** tout ce
  /// qui a déjà tourné, sinon la sphère répondrait au doigt dans le repère
  /// d'origine et partirait de travers dès la deuxième rotation.
  Rot fois(Rot autre) {
    final a = _m;
    final b = autre._m;
    final r = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        r[i * 3 + j] =
            a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
      }
    }
    return Rot(r).dEquerre();
  }

  /// Remet la matrice d'équerre : trois axes de longueur 1, perpendiculaires.
  ///
  /// Sans elle, la sphère se déforme lentement — voir l'avertissement de la
  /// classe. Gardé par `test/sphere_test.dart`.
  Rot dEquerre() {
    // Ligne 1 : normalisée.
    var l1 = Vec3(_m[0], _m[1], _m[2]).normalise;
    // Ligne 2 : on lui retire ce qu'elle a en commun avec la première.
    final l2brut = Vec3(_m[3], _m[4], _m[5]);
    final d = l1.x * l2brut.x + l1.y * l2brut.y + l1.z * l2brut.z;
    var l2 = Vec3(
      l2brut.x - l1.x * d,
      l2brut.y - l1.y * d,
      l2brut.z - l1.z * d,
    ).normalise;
    // Ligne 3 : le produit vectoriel des deux autres, donc perpendiculaire par
    // construction. Aucune correction n'est possible ici : elle est exacte.
    final l3 = Vec3(
      l1.y * l2.z - l1.z * l2.y,
      l1.z * l2.x - l1.x * l2.z,
      l1.x * l2.y - l1.y * l2.x,
    );
    return Rot([l1.x, l1.y, l1.z, l2.x, l2.y, l2.z, l3.x, l3.y, l3.z]);
  }
}

/// Ce qu'on sait d'un ami une fois projeté à l'écran.
class PointVu {
  const PointVu({
    required this.index,
    required this.centre,
    required this.echelle,
    required this.profondeur,
    required this.opacite,
  });

  /// Sa place dans la liste d'amis.
  final int index;

  /// Où il tombe à l'écran.
  final Offset centre;

  /// Combien il est grossi : > 1 devant, < 1 derrière.
  final double echelle;

  /// De −1 (au fond) à +1 (juste devant l'œil). Sert à l'ordre de dessin.
  final double profondeur;

  final double opacite;
}

/// La sphère : la répartition des amis dessus, sa taille, et sa projection.
abstract final class Sphere {
  /// Distance de l'œil au centre, en multiples du rayon.
  ///
  /// ⚠️ **C'est ce nombre qui décide de la force du relief**, et rien d'autre.
  /// Trop grand, la sphère paraît plate (projection presque orthographique) ;
  /// trop petit, l'ami de devant devient énorme et écrase les autres. À 3, le
  /// devant est 1,5 fois plus grand que le milieu et l'arrière 0,75 fois —
  /// c'est net sans être caricatural.
  static const camera = 3.0;

  /// Ce qui reste d'opacité à un ami situé tout au fond.
  ///
  /// ⚠️ **Il n'est pas caché.** Jay demande une **bulle** : on voit au travers.
  /// Cacher l'arrière rendrait la moitié des amis inexistants, et avec cinq
  /// amis l'écran paraîtrait vide. Ici ils sont là, petits et pâles — et c'est
  /// ce qui donne envie de tourner.
  static const opaciteAuFond = 0.30;

  /// Répartit [combien] points sur la sphère unité, **presque uniformément**.
  ///
  /// ## Pourquoi la spirale d'or et pas des anneaux
  ///
  /// Une répartition en anneaux (latitude par latitude) entasse les points aux
  /// pôles et les espace à l'équateur : les amis se chevaucheraient en haut et
  /// en bas, et personne ne le verrait avant d'en avoir cinquante.
  ///
  /// La spirale d'or place le point *i* à la latitude qui découpe la sphère en
  /// tranches d'aires égales, et le fait tourner de l'angle d'or à chaque pas.
  /// C'est la seule construction simple qui donne un écart régulier **quel que
  /// soit le nombre d'amis** — donc qui « s'adapte au nombre d'amis », comme
  /// demandé.
  static List<Vec3> points(int combien) {
    if (combien <= 0) return const [];
    if (combien == 1) return const [Vec3(0, 0, 1)];
    // L'angle d'or : π (3 − √5) ≈ 2,39996 rad.
    final angleDor = math.pi * (3 - math.sqrt(5));
    return [
      for (var i = 0; i < combien; i++)
        () {
          // y balaie [−1, 1] par pas égaux : chaque tranche a la même aire.
          final y = 1 - (i / (combien - 1)) * 2;
          final r = math.sqrt(math.max(0, 1 - y * y));
          final theta = angleDor * i;
          return Vec3(math.cos(theta) * r, y, math.sin(theta) * r);
        }(),
    ];
  }

  /// Le rayon de la sphère, **déduit du nombre d'amis**.
  ///
  /// ## La règle, et pourquoi c'en est une
  ///
  /// Sur une sphère de N points bien répartis, chacun occupe une aire de
  /// `4π/N` : l'écart angulaire moyen entre voisins vaut donc `√(4π/N)`. Pour
  /// que deux photos ne se touchent pas, l'arc qui les sépare — `rayon × écart`
  /// — doit valoir au moins un diamètre, plus un peu d'air.
  ///
  /// ➡️ **`rayon = diamètre × marge ⁄ √(4π/N)`.**
  ///
  /// Conséquence directe, et c'est elle qui donne le bon toucher : **plus on a
  /// d'amis, plus la sphère est grande**. Comme le doigt suit la surface au
  /// millimètre (voir [angleDeGeste]), une grande sphère tourne moins vite pour
  /// le même geste. Un monde plus peuplé paraît donc plus **lourd** — ce n'est
  /// pas un effet ajouté, c'est la physique du modèle.
  ///
  /// [rayonMinimum] empêche une sphère minuscule quand on a trois amis : en
  /// dessous, tout se tasserait au centre de l'écran.
  static double rayon({
    required int combien,
    required double diametre,
    required double rayonMinimum,
    double marge = 1.35,
  }) {
    if (combien <= 1) return rayonMinimum;
    final ecart = math.sqrt(4 * math.pi / combien);
    return math.max(rayonMinimum, diametre * marge / ecart);
  }

  /// L'angle dont tourne la sphère quand le doigt parcourt [distance] pixels.
  ///
  /// ⚠️ **C'est la règle qui fait que le doigt « tient » la sphère.** L'arc
  /// parcouru à la surface vaut exactement la distance parcourue par le doigt :
  /// la photo qu'on a touchée reste sous le doigt. Toute autre formule donne la
  /// sensation d'un contenu qui glisse.
  static double angleDeGeste(double distance, double rayonAffiche) =>
      rayonAffiche <= 0 ? 0 : distance / rayonAffiche;

  /// L'axe autour duquel tourner pour un geste de [delta] pixels à l'écran.
  ///
  /// Il est **perpendiculaire au geste**, dans le plan de l'écran : c'est ce
  /// qui fait qu'on pousse la sphère là où le doigt va.
  ///
  /// ⚠️ L'ordre `(dy, dx)` n'est pas une coquille : à l'écran, y descend. Un
  /// glissement vers la droite doit tourner autour de l'axe vertical, un
  /// glissement vers le bas autour de l'axe horizontal.
  static Vec3 axeDeGeste(Offset delta) => Vec3(delta.dy, delta.dx, 0).normalise;

  /// Projette un point de la sphère unité DÉJÀ TOURNÉ.
  ///
  /// Projection **en perspective**, pas orthographique : c'est la différence
  /// entre un disque décoré et un volume. L'ami de devant est réellement plus
  /// près de l'œil, donc plus grand.
  static PointVu projeter({
    required int index,
    required Vec3 p,
    required double rayonAffiche,
    required Size ecran,
  }) {
    // Facteur de perspective : 1 au niveau du centre, > 1 devant, < 1 derrière.
    final f = camera / (camera - p.z);
    return PointVu(
      index: index,
      centre: Offset(
        ecran.width / 2 + p.x * rayonAffiche * f,
        // ⚠️ y inversé : dans l'espace y monte, à l'écran y descend.
        ecran.height / 2 - p.y * rayonAffiche * f,
      ),
      echelle: f,
      profondeur: p.z,
      opacite: opaciteAuFond + (1 - opaciteAuFond) * ((p.z + 1) / 2),
    );
  }
}
