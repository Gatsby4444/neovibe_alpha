import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/library_item.dart';
import 'package:neovibe/features/library/album_editor/album_draft.dart';
import 'package:neovibe/features/library/album_editor/color_grade.dart';

AlbumDraftMedia photo(String id, {int w = 3000, int h = 4000}) =>
    AlbumDraftMedia(
      id: id,
      source: File('/tmp/$id.jpg'),
      isVideo: false,
      srcWidth: w,
      srcHeight: h,
    );

AlbumDraftMedia video(String id, int ms) => AlbumDraftMedia(
  id: id,
  source: File('/tmp/$id.mp4'),
  isVideo: true,
  srcWidth: 1920,
  srcHeight: 1080,
  durationMs: ms,
);

void main() {
  group('AlbumDraft — les règles de Jay', () {
    test('11 médias au plus : le douzième est ignoré', () {
      var d = const AlbumDraft();
      d = d.add([for (var i = 0; i < 13; i++) photo('p$i')]);
      expect(d.media.length, kAlbumMaxMedia);
      expect(d.isFull, isTrue);
      expect(d.freeSlots, 0);
    });

    test('réordonner déplace sans perdre', () {
      final d = const AlbumDraft().add([photo('a'), photo('b'), photo('c')]);
      final r = d.reorder(2, 0);
      expect(r.media.map((m) => m.id), ['c', 'a', 'b']);
      expect(d.reorder(1, 1), d);
    });

    test('changer de ratio remet les recadrages à zéro', () {
      final d = const AlbumDraft()
          .add([photo('a')])
          .update('a', (m) => m.copyWith(crop: const CropSpec(zoom: 2)));
      expect(d.media.first.crop.zoom, 2);
      final s = d.withAspect(AlbumAspect.square);
      expect(s.media.first.crop, CropSpec.none);
      // Le même ratio ne touche à rien.
      expect(d.withAspect(AlbumAspect.portrait), same(d));
    });
  });

  group('La découpe d\'une vidéo trop longue', () {
    test('2 min 30 → 60 s + 60 s + 30 s', () {
      final parts = AlbumDraft.splitPlan(150000, freeSlots: 11);
      expect(parts.map((p) => (p.startMs, p.endMs)), [
        (0, 60000),
        (60000, 120000),
        (120000, 150000),
      ]);
    });

    test('bornée par les places libres', () {
      final parts = AlbumDraft.splitPlan(300000, freeSlots: 2);
      expect(parts.length, 2);
      expect(parts.last.endMs, 120000);
    });

    test('une queue de moins d\'une seconde n\'est pas un média', () {
      final parts = AlbumDraft.splitPlan(60500, freeSlots: 11);
      expect(parts.length, 1);
    });

    test('exactement 60 s : un seul morceau, pas de découpe', () {
      expect(AlbumDraft.splitPlan(60000, freeSlots: 11).length, 1);
    });
  });

  group('VideoTrim.normalized', () {
    test('ramène dans la source et sous 60 s', () {
      const t = VideoTrim(startMs: 10000, endMs: 90000, coverMs: 85000);
      final n = t.normalized(100000);
      expect(n.startMs, 10000);
      expect(n.endMs, 70000);
      // La couverture suit : elle ne peut pas être hors du morceau.
      expect(n.coverMs, 69999);
    });

    test('effectiveTrim d\'une vidéo courte = toute la source', () {
      final t = video('v', 42000).effectiveTrim;
      expect((t.startMs, t.endMs), (0, 42000));
    });

    test(
      'effectiveTrim d\'une vidéo longue sans rognage = les 60 premières s',
      () {
        final t = video('v', 90000).effectiveTrim;
        expect((t.startMs, t.endMs), (0, 60000));
      },
    );
  });

  group('CropSpec', () {
    test(
      'zoom 1 = le plus grand cadre du ratio, centré (portrait 3000×4000 en 4:5)',
      () {
        final r = CropSpec.none.sourceRect(3000, 4000, 4 / 5);
        expect(r.width, 3000);
        expect(r.height, closeTo(3750, 0.01));
        expect(r.top, closeTo(125, 0.01));
      },
    );

    test('paysage en 1:1 : le cadre prend toute la hauteur', () {
      final r = CropSpec.none.sourceRect(1920, 1080, 1);
      expect(r.width, 1080);
      expect(r.height, 1080);
      expect(r.left, 420);
    });

    test('le cadre ne sort jamais de la source, même visé au bord', () {
      const c = CropSpec(zoom: 2, cx: 0, cy: 0);
      final r = c.sourceRect(3000, 4000, 4 / 5);
      expect(r.left, 0);
      expect(r.top, 0);
      const d = CropSpec(zoom: 2, cx: 1, cy: 1);
      final r2 = d.sourceRect(3000, 4000, 4 / 5);
      expect(r2.right, 3000);
      expect(r2.bottom, 4000);
    });

    test('déplacer le doigt vers la droite montre plus à gauche', () {
      const c = CropSpec(zoom: 2);
      final p = c.panned(
        100,
        0,
        srcW: 3000,
        srcH: 4000,
        aspect: 4 / 5,
        frameW: 300,
        frameH: 375,
      );
      expect(p.cx, lessThan(c.cx));
      expect(p.cy, c.cy);
    });

    test('le zoom est borné entre 1 et 3', () {
      const c = CropSpec(zoom: 2.5);
      expect(
        c.zoomed(2, srcW: 100, srcH: 100, aspect: 1).zoom,
        CropSpec.maxZoom,
      );
      expect(c.zoomed(0.1, srcW: 100, srcH: 100, aspect: 1).zoom, 1);
    });

    test('normalizedRect est en fractions de la source', () {
      final r = const CropSpec(zoom: 2).normalizedRect(1000, 1000, 1);
      expect(r.width, 0.5);
      expect(r.left, 0.25);
    });
  });

  group('ColorGrade — une seule définition des réglages', () {
    test('aucun réglage = la matrice identité', () {
      final m = ColorGrade.none.toMatrix();
      expect(m.length, 20);
      final (r, g, b) = ColorGrade.apply(m, 12, 200, 77);
      expect((r, g, b), (12.0, 200.0, 77.0));
    });

    test('saturation −1 = noir et blanc (les trois canaux égaux)', () {
      final m = const ColorGrade(saturation: -1).toMatrix();
      final (r, g, b) = ColorGrade.apply(m, 255, 0, 0);
      expect(r, closeTo(g, 0.001));
      expect(g, closeTo(b, 0.001));
      // Le rouge pur pèse 21 % de la luminance.
      expect(r, closeTo(255 * 0.2126, 0.01));
    });

    test('la chaleur pousse le rouge et retient le bleu', () {
      final m = const ColorGrade(warmth: 1).toMatrix();
      final (r, _, b) = ColorGrade.apply(m, 128, 128, 128);
      expect(r, greaterThan(128));
      expect(b, lessThan(128));
    });

    test('le contraste écarte du gris moyen, la luminosité décale tout', () {
      final c = const ColorGrade(contrast: 1).toMatrix();
      final (lo, _, _) = ColorGrade.apply(c, 64, 64, 64);
      final (hi, _, _) = ColorGrade.apply(c, 192, 192, 192);
      expect(lo, lessThan(64));
      expect(hi, greaterThan(192));
      final (mid, _, _) = ColorGrade.apply(c, 128, 128, 128);
      expect(mid, closeTo(128, 0.01));

      final l = const ColorGrade(brightness: 0.5).toMatrix();
      final (v, _, _) = ColorGrade.apply(l, 100, 100, 100);
      expect(v, closeTo(151, 0.01));
    });

    test('le fondu remonte les noirs', () {
      final m = const ColorGrade(fade: 1).toMatrix();
      final (r, _, _) = ColorGrade.apply(m, 0, 0, 0);
      expect(r, 64);
    });

    test('over : les retouches s\'ajoutent au filtre, bornées', () {
      final g = const ColorGrade(saturation: 0.9).over(AlbumFilter.juno.grade);
      expect(g.saturation, 1);
      expect(g.warmth, AlbumFilter.juno.grade.warmth);
    });

    test('tous les filtres ont un nom distinct', () {
      final labels = AlbumFilter.values.map((f) => f.label).toSet();
      expect(labels.length, AlbumFilter.values.length);
    });
  });

  group('Vignette', () {
    test('rien au centre, plein au coin, rien si 0', () {
      expect(Vignette.alphaAt(0, 1), 0);
      expect(Vignette.alphaAt(1, 1), closeTo(0.7, 0.0001));
      expect(Vignette.alphaAt(1, 0), 0);
      expect(Vignette.distance(0.5, 0.5), 0);
      expect(Vignette.distance(0, 0), closeTo(1, 0.0001));
    });
  });
}
