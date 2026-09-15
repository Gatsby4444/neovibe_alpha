import 'dart:io';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' show Vector3;

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/library/album_editor/album_draft.dart';
import 'package:neovibe/features/library/album_editor/crop_geometry.dart';

AlbumDraftMedia photo({
  int w = 3000,
  int h = 4000,
  CropSpec crop = CropSpec.none,
}) => AlbumDraftMedia(
  id: 'p',
  source: File('/tmp/p.jpg'),
  isVideo: false,
  srcWidth: w,
  srcHeight: h,
  crop: crop,
);

void main() {
  group('CropGeometry.inscribed', () {
    test('sans rotation, tout le rectangle', () {
      expect(CropGeometry.inscribed(3000, 4000, 0), (3000.0, 4000.0));
    });

    test('un quart de tour : largeur et hauteur échangées', () {
      final (w, h) = CropGeometry.inscribed(3000, 4000, math.pi / 2);
      expect(w, closeTo(4000, 0.01));
      expect(h, closeTo(3000, 0.01));
    });

    test('un redressement resserre la vue, symétriquement', () {
      final (w1, h1) = CropGeometry.inscribed(3000, 4000, 10 * math.pi / 180);
      final (w2, h2) = CropGeometry.inscribed(3000, 4000, -10 * math.pi / 180);
      expect(w1, lessThan(3000));
      expect(h1, lessThan(4000));
      expect(w1, closeTo(w2, 0.001));
      expect(h1, closeTo(h2, 0.001));
    });
  });

  group('CropGeometry.corners', () {
    test(
      'sans rotation ni zoom, en 3:4 sur un 3:4 : les quatre coins de l\'image',
      () {
        final c = CropGeometry.corners(photo(), 3 / 4);
        expect(c[0], const Offset(0, 0));
        expect(c[1], const Offset(1, 0));
        expect(c[2], const Offset(0, 1));
        expect(c[3], const Offset(1, 1));
      },
    );

    test(
      'les coins restent toujours dans l\'image, même tournée et visée au bord',
      () {
        for (final angle in [-45.0, -20.0, 0.0, 15.0, 45.0]) {
          for (final turns in [0, 1, 2, 3]) {
            final m = photo(
              crop: CropSpec(
                zoom: 1.4,
                cx: 0,
                cy: 1,
                angle: angle,
                turns: turns,
              ),
            );
            for (final p in CropGeometry.corners(m, 3 / 4)) {
              expect(
                p.dx,
                inInclusiveRange(-1e-9, 1 + 1e-9),
                reason: 'angle $angle turns $turns',
              );
              expect(
                p.dy,
                inInclusiveRange(-1e-9, 1 + 1e-9),
                reason: 'angle $angle turns $turns',
              );
            }
          }
        }
      },
    );

    test(
      'un quart de tour : le haut du cadre échantillonne la gauche de la source',
      () {
        // Image tournée de 90° (horaire) : ce qui était à gauche est en haut.
        final c = CropGeometry.corners(
          photo(w: 4000, h: 3000, crop: const CropSpec(turns: 1)),
          3 / 4,
        );
        // Coin haut-gauche du cadre → bas-gauche de la source.
        expect(c[0].dx, closeTo(0, 1e-9));
        expect(c[0].dy, closeTo(1, 1e-9));
        // Coin haut-droit du cadre → haut-gauche de la source.
        expect(c[1].dx, closeTo(0, 1e-9));
        expect(c[1].dy, closeTo(0, 1e-9));
      },
    );

    test('la matrice et les coins racontent la même chose', () {
      final m = photo(
        crop: const CropSpec(zoom: 1.5, cx: 0.4, cy: 0.6, angle: 12),
      );
      const frameW = 300.0, frameH = 400.0;
      final mat = CropGeometry.matrix(m, 3 / 4, frameW: frameW, frameH: frameH);
      final corners = CropGeometry.corners(m, 3 / 4);
      // Le coin haut-gauche du cadre, en pixels source, doit tomber en (0,0) écran.
      final src = Offset(
        corners[0].dx * m.srcWidth,
        corners[0].dy * m.srcHeight,
      );
      final v = mat.transform3(Vector3(src.dx, src.dy, 0));
      expect(v.x, closeTo(0, 1e-6));
      expect(v.y, closeTo(0, 1e-6));
      final src2 = Offset(
        corners[3].dx * m.srcWidth,
        corners[3].dy * m.srcHeight,
      );
      final v2 = mat.transform3(Vector3(src2.dx, src2.dy, 0));
      expect(v2.x, closeTo(frameW, 1e-6));
      expect(v2.y, closeTo(frameH, 1e-6));
    });
  });

  group('gestes', () {
    test('glisser vers la droite montre plus à gauche', () {
      final m = photo(crop: const CropSpec(zoom: 2));
      final p = CropGeometry.panned(m, 3 / 4, 100, 0, frameW: 300);
      expect(p.cx, lessThan(0.5));
      expect(p.cy, 0.5);
    });

    test('le zoom est borné entre 1 et 3, et la visée reste valide', () {
      final m = photo(crop: const CropSpec(zoom: 2.5, cx: 0.9, cy: 0.9));
      expect(CropGeometry.zoomed(m, 3 / 4, 2).zoom, CropSpec.maxZoom);
      final out = CropGeometry.zoomed(m, 3 / 4, 0.1);
      expect(out.zoom, 1);
      // Dézoomé à 1, le cadre couvre tout : le centre est ramené au milieu.
      expect(out.cx, closeTo(0.5, 1e-9));
    });

    test('un quart de tour remet le redressement et la visée', () {
      const c = CropSpec(zoom: 2, cx: 0.2, cy: 0.3, angle: 20, turns: 3);
      final t = c.turned();
      expect(t.turns, 0);
      expect(t.angle, 0);
      expect(t.zoom, 1);
      expect(t.cx, 0.5);
    });
  });
}
