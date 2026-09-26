import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/events/two_finger_gesture.dart';

/// Les gestes à deux doigts de la carte, avec la hiérarchie de Google Maps
/// relevée par Jay (2026-09-26).
void main() {
  // Deux doigts côte à côte, à 160 points l'un de l'autre.
  const a0 = Offset(120, 400), b0 = Offset(280, 400);

  test('rien ne se décide avant le seuil — la carte suit les doigts', () {
    final g = TwoFingerGesture(a0, b0);
    final d = g.update(a0.translate(0, -5), b0.translate(0, -5));
    expect(d.kind, TwoFingerKind.undecided);
    expect(d.kind.pans, isTrue);
  });

  group('règle 2 : glisser ensemble déplace, puis incline', () {
    test("d'abord un déplacement", () {
      final g = TwoFingerGesture(a0, b0);
      final d = g.update(a0.translate(0, -15), b0.translate(0, -15));
      expect(d.kind, TwoFingerKind.pan);
      expect(d.kind.pans, isTrue);
      expect(d.tiltByPx, 0);
    });

    test('au-delà de ~4 mm vers le haut : inclinaison, sans à-coup', () {
      final g = TwoFingerGesture(a0, b0);
      g.update(a0.translate(0, -15), b0.translate(0, -15));
      final bascule = g.update(a0.translate(0, -25), b0.translate(0, -25));
      expect(bascule.kind, TwoFingerKind.tilt);
      expect(bascule.kind.pans, isFalse, reason: 'le déplacement s’arrête');
      expect(bascule.tiltByPx, 0, reason: "l'angle part de là");
      final ensuite = g.update(a0.translate(0, -45), b0.translate(0, -45));
      expect(ensuite.tiltByPx, 20);
    });

    test('…même avec des doigts imparfaits', () {
      // Les doigts montent en se rapprochant un peu, l'un plus que l'autre.
      final g = TwoFingerGesture(a0, b0);
      g.update(a0.translate(2, -12), b0.translate(-2, -14));
      final d = g.update(a0.translate(5, -30), b0.translate(-5, -36));
      expect(d.kind, TwoFingerKind.tilt);
    });

    test('glisser à l’HORIZONTALE reste un déplacement', () {
      final g = TwoFingerGesture(a0, b0);
      final d = g.update(a0.translate(60, -10), b0.translate(60, -10));
      expect(d.kind, TwoFingerKind.pan);
    });

    test('vers le bas : redresse la vue', () {
      final g = TwoFingerGesture(a0, b0);
      g.update(a0.translate(0, 26), b0.translate(0, 26));
      final d = g.update(a0.translate(0, 46), b0.translate(0, 46));
      expect(d.kind, TwoFingerKind.tilt);
      expect(d.tiltByPx, -20);
    });
  });

  group('règle 1 : commencer par zoomer, c’est zoomer seulement', () {
    test("s'écarter zoome", () {
      final g = TwoFingerGesture(a0, b0);
      final d = g.update(a0.translate(-80, 0), b0.translate(80, 0));
      expect(d.kind, TwoFingerKind.zoom);
      expect(d.zoomBy, closeTo(1, 1e-9)); // écart doublé = un niveau
    });

    test('ni rotation ni inclinaison ensuite, même franches', () {
      final g = TwoFingerGesture(a0, b0);
      g.update(a0.translate(-20, 0), b0.translate(20, 0));
      final (a, b) = _orbite(a0, b0, 45, 1.5);
      final d = g.update(a.translate(0, -60), b.translate(0, -60));
      expect(d.kind, TwoFingerKind.zoom);
      expect(d.rotateByDeg, 0);
      expect(d.tiltByPx, 0);
    });
  });

  group('règle 3 : en sens opposés, rotation (et zoom en même temps)', () {
    test('tourner fait tourner', () {
      final g = TwoFingerGesture(a0, b0);
      final (a, b) = _orbite(a0, b0, 30, 1);
      final d = g.update(a, b);
      expect(d.kind, TwoFingerKind.rotate);
      expect(d.rotateByDeg, closeTo(30, 1e-6));
    });

    test('…et zoome si l’écart change pendant la rotation', () {
      final g = TwoFingerGesture(a0, b0);
      final (a1, b1) = _orbite(a0, b0, 15, 1);
      g.update(a1, b1);
      final (a, b) = _orbite(a0, b0, 30, 2);
      final d = g.update(a, b);
      expect(d.kind, TwoFingerKind.rotate);
      expect(d.zoomBy, closeTo(1, 1e-6));
    });
  });
}

/// Les deux doigts tournés de [deg] autour de leur milieu, écart × [echelle].
(Offset, Offset) _orbite(Offset a0, Offset b0, double deg, double echelle) {
  final c = (a0 + b0) / 2;
  final r = deg * math.pi / 180;
  Offset tourne(Offset p) {
    final v = (p - c) * echelle;
    return c +
        Offset(
          v.dx * math.cos(r) - v.dy * math.sin(r),
          v.dx * math.sin(r) + v.dy * math.cos(r),
        );
  }

  return (tourne(a0), tourne(b0));
}
