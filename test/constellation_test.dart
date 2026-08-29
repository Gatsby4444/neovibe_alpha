import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/circle/constellation_screen.dart';

/// La géométrie du nid d'abeille.
///
/// ⚠️ **Un chevauchement ne lève aucune erreur.** Deux pastilles superposées
/// s'affichent très bien : l'une passe sous l'autre, et on croit simplement
/// avoir un ami de moins. Sur trois amis ça se voit ; sur quarante, non. Seul
/// un test qui MESURE les distances peut le garantir.
void main() {
  const pas = 100.0;

  group('Le nid d abeille', () {
    test('rend exactement le nombre de places demande', () {
      for (final n in [0, 1, 2, 6, 7, 19, 40, 137]) {
        expect(Ruche.places(n, pas).length, n, reason: '$n amis');
      }
    });

    test('la premiere place est au centre', () {
      expect(Ruche.places(1, pas).first, Offset.zero);
    });

    test('AUCUNE pastille n en chevauche une autre', () {
      final places = Ruche.places(60, pas);
      for (var i = 0; i < places.length; i++) {
        for (var j = i + 1; j < places.length; j++) {
          final d = (places[i] - places[j]).distance;
          // Un pavage hexagonal régulier met les voisins à exactement `pas`.
          // La tolérance absorbe l'arrondi des racines carrées.
          expect(
            d,
            greaterThan(pas * 0.99),
            reason: 'les places $i et $j se chevauchent (distance $d)',
          );
        }
      }
    });

    test('les voisins immediats sont a la bonne distance', () {
      // Le premier anneau : six voisins, tous à `pas` du centre.
      final places = Ruche.places(7, pas);
      for (var i = 1; i < 7; i++) {
        expect(places[i].distance, closeTo(pas, 0.01), reason: 'voisin $i');
      }
    });

    test('la ruche reste compacte quand elle grandit', () {
      // ⚠️ Ce test protège la lisibilité, pas la correction : une spirale qui
      // s'échapperait en ligne droite passerait tous les tests ci-dessus et
      // donnerait un écran où il faut faire défiler dix minutes.
      final places = Ruche.places(91, pas);
      final rayon = places.fold<double>(0, (r, o) => math.max(r, o.distance));
      // 91 places = cinq anneaux complets autour du centre.
      expect(rayon, lessThan(pas * 6));
    });
  });

  group('La projection spherique', () {
    const rayon = 400.0;

    test('au centre, rien n est deplace ni rapetisse', () {
      // ⚠️ **C'est la garantie de CENTRAGE**, exprimée en une mesure. La
      // première version affichait le coin haut-gauche d'un plan géant ; ici la
      // place 0 est à l'origine et l'origine se projette sur elle-même, donc la
      // première pastille tombe exactement au milieu de l'écran.
      final (vue, echelle) = Ruche.projeter(d: 0, rayon: rayon);
      expect(vue, 0);
      expect(echelle, 1);
    });

    test('rien ne GRANDIT en s eloignant', () {
      // Un effet de sphère mal écrit peut faire regrossir les pastilles
      // au-delà d'un certain angle — et personne ne le verrait sans mesurer.
      var precedente = 1.0;
      for (var d = 0.0; d <= rayon * 1.45; d += 4) {
        final (_, echelle) = Ruche.projeter(d: d, rayon: rayon);
        expect(
          echelle,
          lessThanOrEqualTo(precedente + 1e-9),
          reason: 'a $d px, l echelle est remontee',
        );
        precedente = echelle;
      }
    });

    test('rien ne sort du disque', () {
      for (var d = 0.0; d <= rayon * 1.45; d += 4) {
        final (vue, _) = Ruche.projeter(d: d, rayon: rayon);
        expect(vue, lessThanOrEqualTo(rayon + 1e-9), reason: 'a $d px');
      }
    });

    test('deux pastilles ne se croisent JAMAIS', () {
      // ⚠️ Si la projection se repliait, une pastille plus lointaine
      // apparaîtrait DEVANT une plus proche. L'image resterait jolie, et
      // l'ordre serait faux.
      var precedente = -1.0;
      for (var d = 0.0; d <= rayon * math.pi / 2; d += 4) {
        final (vue, _) = Ruche.projeter(d: d, rayon: rayon);
        expect(vue, greaterThan(precedente), reason: 'repli a $d px');
        precedente = vue;
      }
    });

    test('les pastilles se RESSERRENT en s eloignant', () {
      // C'est ce resserrement qui fait le relief : sans lui on n a qu un
      // rapetissement, et l ecran a l air plat. On mesure donc que l ecart
      // entre deux positions consecutives diminue.
      double ecart(double d) {
        final (a, _) = Ruche.projeter(d: d, rayon: rayon);
        final (b, _) = Ruche.projeter(d: d + 20, rayon: rayon);
        return b - a;
      }

      expect(ecart(rayon * 1.2), lessThan(ecart(rayon * 0.2)));
    });

    test('une pastille ne disparait jamais completement', () {
      final (_, echelle) = Ruche.projeter(d: rayon * 1.45, rayon: rayon);
      expect(echelle, greaterThanOrEqualTo(0.24));
    });
  });
}
