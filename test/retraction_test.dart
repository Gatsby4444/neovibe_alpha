import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/retraction.dart';

/// Ce que ce test défend : la forme qui se rétracte **part exactement du
/// plein écran** et arrive sur un heptagone aux côtés creusés — sans saut
/// entre les deux, puisque c'est le geste de l'utilisateur qui la pilote.
void main() {
  const a = 200.0; // demi-largeur
  const b = 430.0; // demi-hauteur (un écran de téléphone, bien plus haut)

  double r(double theta, double t) => rayonRetracte(theta, a: a, b: b, t: t);

  test('à 0, c\'est le rectangle — pas « presque »', () {
    expect(r(0, 0), moreOrLessEquals(a, epsilon: 0.001));
    expect(r(math.pi, 0), moreOrLessEquals(a, epsilon: 0.001));
    expect(r(math.pi / 2, 0), moreOrLessEquals(b, epsilon: 0.001));
    // Un coin : les deux bornes se rejoignent sur la plus petite.
    final coin = math.atan2(b, a);
    expect(r(coin, 0), moreOrLessEquals(math.sqrt(a * a + b * b), epsilon: 1));
  });

  test(
    'à 1, tout tient dans le plus petit côté, et les côtés sont creusés',
    () {
      var max = 0.0;
      var min = double.infinity;
      for (var i = 0; i < 360; i++) {
        final v = r(2 * math.pi * i / 360, 1);
        max = math.max(max, v);
        min = math.min(min, v);
      }
      // L'heptagone est inscrit dans la largeur : il ne déborde pas.
      expect(max, lessThanOrEqualTo(a + 0.5));
      // Et il n'est pas un cercle : un creux sépare sommets et côtés.
      expect(min, lessThan(max * 0.93));
    },
  );

  test('le chemin ne saute pas : il se rétracte, angle par angle', () {
    for (var i = 0; i < 60; i++) {
      final theta = 2 * math.pi * i / 60;
      var precedent = r(theta, 0);
      for (var k = 1; k <= 10; k++) {
        final v = r(theta, k / 10);
        expect(
          v,
          lessThanOrEqualTo(precedent + 0.001),
          reason: 'le rayon doit décroître, pas osciller',
        );
        precedent = v;
      }
    }
  });

  test('le contour est fermé et tient dans la boîte', () {
    const taille = Size(2 * a, 2 * b);
    for (final t in [0.0, 0.3, 0.7, 1.0]) {
      final bornes = formeRetractee(taille, t).getBounds();
      expect(bornes.left, greaterThanOrEqualTo(-0.5));
      expect(bornes.top, greaterThanOrEqualTo(-0.5));
      expect(bornes.right, lessThanOrEqualTo(taille.width + 0.5));
      expect(bornes.bottom, lessThanOrEqualTo(taille.height + 0.5));
    }
  });
}
