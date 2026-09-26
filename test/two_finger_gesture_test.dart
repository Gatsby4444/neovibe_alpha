import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/events/two_finger_gesture.dart';

/// Les gestes à deux doigts de la carte (2026-09-26), tels que Jay les a
/// définis — et reconnus par le mouvement qui DOMINE, comme Google Maps.
void main() {
  // Deux doigts côte à côte, à 160 points l'un de l'autre.
  const a0 = Offset(120, 400), b0 = Offset(280, 400);

  test('rien ne se décide avant 10 points de course', () {
    final g = TwoFingerGesture(a0, b0);
    final d = g.update(a0.translate(0, -6), b0.translate(0, -6));
    expect(d.kind, TwoFingerKind.undecided);
  });

  test('deux doigts qui MONTENT ensemble inclinent la vue', () {
    final g = TwoFingerGesture(a0, b0);
    final d = g.update(a0.translate(0, -40), b0.translate(0, -40));
    expect(d.kind, TwoFingerKind.tilt);
    expect(d.tiltByPx, 40);
    expect(d.zoomBy, 0);
  });

  test("…même imparfaitement : écart qui bouge un peu, doigts de travers", () {
    // 🔴 Le cas que Mapbox prenait pour un zoom : les doigts montent de 40
    // en se rapprochant de 12, et l'un monte un peu plus que l'autre.
    final g = TwoFingerGesture(a0, b0);
    final d = g.update(a0.translate(6, -36), b0.translate(-6, -44));
    expect(d.kind, TwoFingerKind.tilt);
  });

  test('les doigts qui descendent ensemble redressent la vue', () {
    final g = TwoFingerGesture(a0, b0);
    final d = g.update(a0.translate(0, 30), b0.translate(0, 30));
    expect(d.kind, TwoFingerKind.tilt);
    expect(d.tiltByPx, -30);
  });

  test("s'écarter zoome, sans tourner ni incliner", () {
    final g = TwoFingerGesture(a0, b0);
    final d = g.update(a0.translate(-80, 0), b0.translate(80, 0));
    expect(d.kind, TwoFingerKind.zoom);
    expect(d.zoomBy, closeTo(1, 1e-9)); // écart doublé = un niveau
    expect(d.rotateByDeg, 0);
  });

  test("un pincement un peu de travers ne fait PAS tourner la carte", () {
    final g = TwoFingerGesture(a0, b0);
    // Écart ×1,5 avec 10° de biais.
    final d = g.update(
      _orbite(a0, b0, 10, 1.5).$1,
      _orbite(a0, b0, 10, 1.5).$2,
    );
    expect(d.kind, TwoFingerKind.zoom);
    expect(d.rotateByDeg, 0);
  });

  test('…mais au-delà de 20°, le zoom tourne aussi, sans à-coup', () {
    final g = TwoFingerGesture(a0, b0);
    g.update(_orbite(a0, b0, 5, 1.5).$1, _orbite(a0, b0, 5, 1.5).$2);
    final rejoint = g.update(
      _orbite(a0, b0, 21, 1.5).$1,
      _orbite(a0, b0, 21, 1.5).$2,
    );
    expect(rejoint.rotateByDeg, closeTo(0, 1e-9), reason: 'pas de saut de 20°');
    final ensuite = g.update(
      _orbite(a0, b0, 31, 1.5).$1,
      _orbite(a0, b0, 31, 1.5).$2,
    );
    expect(ensuite.rotateByDeg, closeTo(10, 1e-6));
  });

  test('tourner en sens opposés fait tourner la carte (et peut zoomer)', () {
    final g = TwoFingerGesture(a0, b0);
    final (a, b) = _orbite(a0, b0, 30, 1);
    final d = g.update(a, b);
    expect(d.kind, TwoFingerKind.rotate);
    expect(d.rotateByDeg, closeTo(30, 1e-6));
  });

  test("une fois décidé, le geste ne change plus d'avis", () {
    final g = TwoFingerGesture(a0, b0);
    expect(
      g.update(a0.translate(0, -40), b0.translate(0, -40)).kind,
      TwoFingerKind.tilt,
    );
    // Les doigts s'écartent ensuite : on reste en inclinaison.
    expect(
      g.update(a0.translate(-60, -40), b0.translate(60, -40)).kind,
      TwoFingerKind.tilt,
    );
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
