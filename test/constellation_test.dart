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
}
