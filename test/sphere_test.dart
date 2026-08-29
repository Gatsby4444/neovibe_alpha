import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/circle/sphere.dart';

/// La géométrie de la bulle.
///
/// ⚠️ **Aucun de ces défauts ne lève d'erreur.** Une répartition qui entasse aux
/// pôles, une rotation qui se déforme en œuf au bout de dix minutes, un ami de
/// derrière peint devant : tout cela s'affiche parfaitement. Ça ne se voit
/// qu'en mesurant — ou trop tard, chez Jay.
void main() {
  double produitScalaire(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

  group('La repartition sur la sphere', () {
    test('rend exactement le nombre demande', () {
      for (final n in [0, 1, 2, 5, 40, 137]) {
        expect(Sphere.points(n).length, n, reason: '$n amis');
      }
    });

    test('tous les points sont SUR la sphere, aucun dedans', () {
      for (final p in Sphere.points(200)) {
        expect(p.longueur, closeTo(1, 1e-9));
      }
    });

    test('personne ne s entasse aux poles', () {
      // 🔴 C'est le défaut d'une répartition par anneaux de latitude : les
      // points se serrent en haut et en bas, et deux amis se superposent —
      // invisible tant qu'on en a moins d'une vingtaine.
      //
      // On mesure l'écart MINIMAL entre deux points et on exige qu'il reste
      // proche de l'écart moyen attendu.
      for (final n in [12, 60, 200]) {
        final points = Sphere.points(n);
        final attendu = math.sqrt(4 * math.pi / n);
        var minimum = double.infinity;
        for (var i = 0; i < points.length; i++) {
          for (var j = i + 1; j < points.length; j++) {
            final angle = math.acos(
              produitScalaire(points[i], points[j]).clamp(-1.0, 1.0),
            );
            if (angle < minimum) minimum = angle;
          }
        }
        expect(
          minimum,
          greaterThan(attendu * 0.5),
          reason: 'avec $n amis, deux points sont trop proches',
        );
      }
    });
  });

  group('La taille de la sphere s adapte au nombre d amis', () {
    double r(int n) =>
        Sphere.rayon(combien: n, diametre: 72, rayonMinimum: 100);

    test('elle GRANDIT avec le nombre d amis', () {
      expect(r(200), greaterThan(r(60)));
      expect(r(60), greaterThan(r(20)));
    });

    test('elle ne descend jamais sous le minimum', () {
      for (final n in [0, 1, 2, 3, 8]) {
        expect(
          Sphere.rayon(combien: n, diametre: 72, rayonMinimum: 150),
          greaterThanOrEqualTo(150),
          reason: '$n amis',
        );
      }
    });

    test('deux voisins ne se chevauchent jamais, quel que soit le nombre', () {
      // ⚠️ **C'est LA règle**, celle qui fait que « ça s'adapte au nombre
      // d'amis ». L'arc entre deux voisins doit rester plus grand qu'une photo.
      const diametre = 72.0;
      for (final n in [10, 50, 150, 400]) {
        final rayon = Sphere.rayon(
          combien: n,
          diametre: diametre,
          rayonMinimum: 100,
        );
        final ecart = math.sqrt(4 * math.pi / n);
        expect(
          rayon * ecart,
          greaterThan(diametre),
          reason: 'avec $n amis les photos se toucheraient',
        );
      }
    });
  });

  group('La rotation', () {
    test('l identite ne bouge rien', () {
      const p = Vec3(0.3, -0.5, 0.8);
      final q = Rot.identite.applique(p);
      expect(q.x, closeTo(p.x, 1e-12));
      expect(q.y, closeTo(p.y, 1e-12));
      expect(q.z, closeTo(p.z, 1e-12));
    });

    test('un quart de tour autour de la verticale amene l avant a droite', () {
      // Le point de devant est (0,0,1). Après un quart de tour, il doit être
      // sur +x, c'est-à-dire à droite de l'écran.
      final r = Rot.axeAngle(const Vec3(0, 1, 0), math.pi / 2);
      final p = r.applique(const Vec3(0, 0, 1));
      expect(p.x, closeTo(1, 1e-9));
      expect(p.z, closeTo(0, 1e-9));
    });

    test('elle conserve les longueurs', () {
      final r = Rot.axeAngle(const Vec3(1, 2, 3), 1.1);
      for (final p in Sphere.points(30)) {
        expect(r.applique(p).longueur, closeTo(1, 1e-9));
      }
    });

    test('elle reste EXACTE apres des milliers de compositions', () {
      // ⚠️ **La tolérance de 1e-14 n'est pas décorative, elle est mesurée.**
      // Une première version de ce test tolérait 1e-6 : il passait aussi bien
      // AVEC que SANS la remise d'équerre, donc il ne prouvait rien — et il
      // laissait croire qu'une ligne du code servait à quelque chose.
      //
      // Relevé le 2026-08-30, après 5 000 compositions :
      //   sans remise d'équerre  ->  3,0e-13
      //   avec                   ->  2,2e-16 (la précision de la machine)
      //
      // À 1e-14, le test tombe quand on retire la ligne. C'est ce qui en fait
      // une mesure.
      var r = Rot.identite;
      final pas = Rot.axeAngle(const Vec3(0.3, 1, 0.2), 0.017);
      for (var i = 0; i < 5000; i++) {
        r = pas.fois(r);
      }
      for (final p in Sphere.points(20)) {
        expect(
          r.applique(p).longueur,
          closeTo(1, 1e-14),
          reason: 'la rotation a cesse d etre exacte',
        );
      }
    });
  });

  group('La projection', () {
    const ecran = Size(400, 800);
    const rayon = 150.0;

    PointVu vu(Vec3 p) =>
        Sphere.projeter(index: 0, p: p, rayonAffiche: rayon, ecran: ecran);

    test('le point de devant est plus GROS que celui de derriere', () {
      // C'est le relief. Sans lui, on a un disque décoré, pas un volume.
      expect(vu(const Vec3(0, 0, 1)).echelle, greaterThan(1));
      expect(vu(const Vec3(0, 0, -1)).echelle, lessThan(1));
      expect(
        vu(const Vec3(0, 0, 1)).echelle,
        greaterThan(vu(const Vec3(0, 0, -1)).echelle * 1.5),
      );
    });

    test('le pole avant tombe au CENTRE de l ecran', () {
      // ⚠️ C'est la garantie de centrage, exprimée en mesure — le reproche
      // « ce n'est pas centré » de la première version.
      final c = vu(const Vec3(0, 0, 1)).centre;
      expect(c.dx, closeTo(ecran.width / 2, 1e-9));
      expect(c.dy, closeTo(ecran.height / 2, 1e-9));
    });

    test('le haut de la sphere est en HAUT de l ecran', () {
      // À l'écran, y descend ; dans l'espace, y monte. Une inversion oubliée
      // retournerait toute la bulle sans qu'aucun test de longueur ne bronche.
      expect(vu(const Vec3(0, 1, 0)).centre.dy, lessThan(ecran.height / 2));
      expect(vu(const Vec3(0, -1, 0)).centre.dy, greaterThan(ecran.height / 2));
    });

    test('ce qui est derriere reste VISIBLE, mais pale', () {
      // Jay a demandé une bulle : on voit au travers. Cacher l'arrière rendrait
      // la moitié des amis inexistants.
      final fond = vu(const Vec3(0, 0, -1));
      expect(fond.opacite, greaterThan(0));
      expect(fond.opacite, lessThan(0.45));
      expect(vu(const Vec3(0, 0, 1)).opacite, closeTo(1, 1e-9));
    });

    test('la profondeur permet de trier du fond vers l avant', () {
      expect(
        vu(const Vec3(0, 0, 1)).profondeur,
        greaterThan(vu(const Vec3(0, 0, -1)).profondeur),
      );
    });
  });

  group('Le geste tient la sphere', () {
    test('l arc parcouru vaut la distance du doigt', () {
      // ⚠️ La règle qui fait que la photo touchée reste sous le doigt. Toute
      // autre formule donne la sensation d'un contenu qui glisse.
      const rayon = 200.0;
      expect(Sphere.angleDeGeste(200, rayon) * rayon, closeTo(200, 1e-9));
      expect(Sphere.angleDeGeste(50, rayon) * rayon, closeTo(50, 1e-9));
    });

    test('une sphere plus grande tourne MOINS pour le meme geste', () {
      // Conséquence directe : un monde plus peuplé paraît plus lourd.
      expect(
        Sphere.angleDeGeste(100, 400),
        lessThan(Sphere.angleDeGeste(100, 150)),
      );
    });

    test('un rayon nul ne fait pas exploser le calcul', () {
      expect(Sphere.angleDeGeste(100, 0), 0);
    });

    test('l axe est perpendiculaire au geste', () {
      // Glissement horizontal, axe vertical. Glissement vertical, axe
      // horizontal. Une inversion ferait tourner la bulle de travers.
      final horizontal = Sphere.axeDeGeste(const Offset(10, 0));
      expect(horizontal.y.abs(), closeTo(1, 1e-9));
      final vertical = Sphere.axeDeGeste(const Offset(0, 10));
      expect(vertical.x.abs(), closeTo(1, 1e-9));
    });

    test('un geste nul rend un axe valide, pas des NaN', () {
      final axe = Sphere.axeDeGeste(Offset.zero);
      expect(axe.longueur, closeTo(1, 1e-9));
    });
  });
}
