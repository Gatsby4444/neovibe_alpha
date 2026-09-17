import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/library_item.dart';
import 'package:neovibe/features/library/album_editor/album_draft.dart';
import 'package:neovibe/features/library/album_editor/color_grade.dart';
import 'package:neovibe/features/library/album_editor/overlay_model.dart';

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
    test('20 médias au plus : le vingt-et-unième est ignoré', () {
      var d = const AlbumDraft();
      d = d.add([for (var i = 0; i < 25; i++) photo('p$i')]);
      expect(kAlbumMaxMedia, 20, reason: 'la règle d\'Instagram (Jay, 17/09)');
      expect(d.media.length, 20);
      expect(d.isFull, isTrue);
      expect(d.freeSlots, 0);
    });

    test('réordonner déplace sans perdre', () {
      final d = const AlbumDraft().add([photo('a'), photo('b'), photo('c')]);
      final r = d.reorder(2, 0);
      expect(r.media.map((m) => m.id), ['c', 'a', 'b']);
      expect(d.reorder(1, 1), d);
    });

    test('trois formats, et le premier média propose le sien', () {
      // Les trois d'Instagram, repris le 2026-09-17.
      expect(AlbumAspect.portrait.ratio, 0.8);
      expect(AlbumAspect.square.ratio, 1);
      expect(AlbumAspect.landscape.ratio, 1.91);

      // Une photo verticale de téléphone (3:4, ou même 9:16) : portrait.
      expect(AlbumDraft.aspectFor(photo('a')), AlbumAspect.portrait);
      expect(
        AlbumDraft.aspectFor(photo('b', w: 1080, h: 1920)),
        AlbumAspect.portrait,
      );
      // Un carré reste carré, un 16:9 devient le paysage 1,91:1.
      expect(
        AlbumDraft.aspectFor(photo('c', w: 1000, h: 1000)),
        AlbumAspect.square,
      );
      expect(
        AlbumDraft.aspectFor(photo('d', w: 1920, h: 1080)),
        AlbumAspect.landscape,
      );
    });

    test('changer de format remet les cadrages à zéro', () {
      final d = const AlbumDraft()
          .add([photo('a'), photo('b')])
          .update(
            'a',
            (m) => m.copyWith(crop: const CropSpec(zoom: 2, cx: 0.2)),
          );
      expect(d.media.first.crop.zoom, 2);

      final carre = d.withAspect(AlbumAspect.square);
      expect(carre.aspect, AlbumAspect.square);
      // Un cadrage est relatif à SON cadre : gardé, il montrerait autre
      // chose que ce que l'utilisateur avait choisi, sans le dire.
      expect(carre.media.every((m) => m.crop == CropSpec.none), isTrue);

      // Le même format : rien ne bouge (on ne perd pas un cadrage pour rien).
      expect(carre.withAspect(AlbumAspect.square), same(carre));
    });

    test('le mode Flow : 9:16, une vidéo, trois minutes, pas de choix', () {
      // La troisième porte de « Publier » (Jay, 2026-09-18).
      final f = const AlbumDraft(
        aspect: AlbumAspect.reel,
        flow: true,
      ).add([video('v', 5000), video('w', 5000)]);
      expect(AlbumAspect.reel.ratio, 9 / 16);
      expect(f.media.length, 1, reason: 'un Flow : UNE vidéo');
      expect(f.isFull, isTrue);
      expect(f.maxVideoMs, kFlowMaxVideoMs);
      expect(kFlowMaxVideoMs, 180000);
      // Le format ne se change pas : un Flow est en 9:16, point.
      expect(f.withAspect(AlbumAspect.square).aspect, AlbumAspect.reel);
    });

    test('« Éditeur Flow » convertit sur place, cadrages remis', () {
      final d = const AlbumDraft(aspect: AlbumAspect.landscape)
          .add([video('v', 5000)])
          .update('v', (m) => m.copyWith(crop: const CropSpec(zoom: 2)));
      final f = d.enFlow();
      expect(f.flow, isTrue);
      expect(f.aspect, AlbumAspect.reel);
      expect(f.media.single.crop, CropSpec.none);
      // Une publication ordinaire, elle, reste à une minute.
      expect(d.maxVideoMs, kAlbumMaxVideoMs);
    });

    test('une vidéo toute seule est reconnue : ce sera un Flow', () {
      expect(const AlbumDraft().add([video('v', 5000)]).videoSeule, isTrue);
      // Accompagnée, c'est un carrousel : ça passe.
      expect(
        const AlbumDraft().add([video('v', 5000), photo('p')]).videoSeule,
        isFalse,
      );
      // Une photo seule est une publication ordinaire.
      expect(const AlbumDraft().add([photo('p')]).videoSeule, isFalse);
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
      'zoom 1 = le plus grand cadre du ratio, centré (3000×4000 en 3:4)',
      () {
        final r = CropSpec.none.rectWithin(3000, 4000, 3 / 4);
        expect(r.width, 3000);
        expect(r.height, closeTo(4000, 0.01));
        expect(r.top, closeTo(0, 0.01));
      },
    );

    test('paysage en 1:1 : le cadre prend toute la hauteur', () {
      final r = CropSpec.none.rectWithin(1920, 1080, 1);
      expect(r.width, 1080);
      expect(r.height, 1080);
      expect(r.left, 420);
    });

    test('le cadre ne sort jamais du rectangle, même visé au bord', () {
      const c = CropSpec(zoom: 2, cx: 0, cy: 0);
      final r = c.rectWithin(3000, 4000, 3 / 4);
      expect(r.left, 0);
      expect(r.top, 0);
      const d = CropSpec(zoom: 2, cx: 1, cy: 1);
      final r2 = d.rectWithin(3000, 4000, 3 / 4);
      expect(r2.right, 3000);
      expect(r2.bottom, 4000);
    });

    test('la rotation totale : quarts de tour + redressement', () {
      expect(
        const CropSpec(turns: 1, angle: 10).radians * 180 / math.pi,
        closeTo(100, 1e-9),
      );
      expect(CropSpec.none.isUpright, isTrue);
    });
  });

  group('ColorGrade — intensité, Lux, contrat des shaders', () {
    test('scaled(0) ne fait rien, scaled(1) est le filtre entier', () {
      final g = AlbumFilter.xpro.grade;
      expect(g.scaled(0).isIdentity, isTrue);
      expect(g.scaled(1), g);
      expect(g.scaled(0.5).contrast, closeTo(g.contrast / 2, 1e-9));
    });

    test(
      'Lux se replie dans les autres réglages et n\'atteint pas le shader',
      () {
        const g = ColorGrade(lux: 1);
        final r = g.resolved;
        expect(r.lux, 0);
        expect(r.contrast, greaterThan(0));
        expect(r.shadows, greaterThan(0));
        // Le shader lit 24 nombres, dans un ordre fixé.
        final u = g.toUniforms();
        expect(u.length, ColorGrade.uniformCount);
        expect(u[20], r.shadows);
        expect(u[23], 0);
      },
    );

    test('la matrice colonne par colonne : l\'identité donne la diagonale', () {
      final u = ColorGrade.none.toUniforms();
      expect(u.sublist(0, 16), [
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
      ]);
      expect(u.sublist(16, 20), [0, 0, 0, 0]);
    });
  });

  group('Calques', () {
    test('un geste déplace, zoome et tourne, borné', () {
      const t = TextOverlay(id: 't', text: 'Salut');
      final g = t.gestured(
        frameW: 300,
        frameH: 400,
        halfW: 10,
        halfH: 10,
        delta: const Offset(30, -40),
        scaleFactor: 10,
        rotationDelta: 0.5,
      );
      expect(g.cx, closeTo(0.6, 1e-9));
      expect(g.cy, closeTo(0.4, 1e-9));
      expect(g.scale, OverlayObject.maxScale);
      expect(g.rotation, 0.5);
    });

    test('un calque est bloqué au bord du cadre, jamais au-delà (Jay)', () {
      const t = TextOverlay(id: 't', text: 'x');
      // Boîte 100×20 : le centre ne peut pas approcher le bord gauche à
      // moins de 50 px, ni le haut à moins de 10 px.
      final g = t.gestured(
        frameW: 300,
        frameH: 400,
        halfW: 50,
        halfH: 10,
        delta: const Offset(-900, 900),
      );
      expect(g.cx, closeTo(50 / 300, 1e-9));
      expect(g.cy, closeTo(1 - 10 / 400, 1e-9));
    });

    test("tourné d'un quart, c'est la boîte tournée qui compte", () {
      const t = TextOverlay(id: 't', text: 'x', rotation: math.pi / 2);
      final g = t.gestured(
        frameW: 300,
        frameH: 400,
        halfW: 50,
        halfH: 10,
        delta: const Offset(-900, -900),
      );
      // À 90°, la boîte fait 20 de large et 100 de haut.
      expect(g.cx, closeTo(10 / 300, 1e-6));
      expect(g.cy, closeTo(50 / 400, 1e-6));
    });

    test('un calque plus large que le cadre est centré', () {
      const t = TextOverlay(id: 't', text: 'x', cx: 0.1);
      final g = t.gestured(frameW: 300, frameH: 400, halfW: 200, halfH: 10);
      expect(g.cx, 0.5);
    });

    test('hits : un point sur le calque tourné', () {
      const t = TextOverlay(
        id: 't',
        text: 'x',
        cx: 0.5,
        cy: 0.5,
        rotation: math.pi / 2,
      );
      // Boîte 100×20 non tournée ; tournée d'un quart, elle est verticale.
      expect(t.hits(const Offset(150, 240), 300, 400, 50, 10), isTrue);
      expect(t.hits(const Offset(190, 200), 300, 400, 50, 10), isFalse);
    });

    test('withOverlay remplace par identifiant, withoutOverlay retire', () {
      final m = photo('p')
          .withOverlay(const TextOverlay(id: 'a', text: '1'))
          .withOverlay(const StickerOverlay(id: 'b', emoji: '🔥'))
          .withOverlay(const TextOverlay(id: 'a', text: '2'));
      expect(m.overlays.length, 2);
      expect((m.overlays.first as TextOverlay).text, '2');
      expect(m.withoutOverlay('a').overlays.map((o) => o.id), ['b']);
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
