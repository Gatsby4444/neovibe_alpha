import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/events/my_point_motion.dart';

/// Le mouvement de mon point sur la carte (2026-09-25) : il glisse d'un
/// relevé au suivant, saute les corrections, et la flèche tourne par le plus
/// court chemin.
void main() {
  final t0 = DateTime(2026, 9, 25, 20);
  Duration ms(int n) => Duration(milliseconds: n);

  test('le premier relevé se pose sans glisser', () {
    final m = MyPointMotion()..setFix(50.6368, 3.0708, 20, t0);
    final f = m.frameAt(t0)!;
    expect(f.lat, 50.6368);
    expect(f.lon, 3.0708);
    expect(m.settledAt(t0), isTrue);
  });

  test('le suivant GLISSE, en autant de temps que la cadence', () {
    final m = MyPointMotion()
      ..setFix(50.6368, 3.0708, 20, t0)
      // ~11 m plus au nord, une seconde après.
      ..setFix(50.6369, 3.0708, 20, t0.add(ms(1000)));
    final debut = t0.add(ms(1000));
    // Au départ : encore à l'ancien point.
    expect(m.frameAt(debut)!.lat, closeTo(50.6368, 1e-9));
    // À mi-chemin : entre les deux, ni figé ni arrivé.
    final mi = m.frameAt(debut.add(ms(500)))!.lat;
    expect(mi, greaterThan(50.6368));
    expect(mi, lessThan(50.6369));
    expect(m.settledAt(debut.add(ms(500))), isFalse);
    // Au bout de la seconde : arrivé, et plus rien à redessiner.
    expect(m.frameAt(debut.add(ms(1000)))!.lat, closeTo(50.6369, 1e-9));
    expect(m.settledAt(debut.add(ms(1000))), isTrue);
  });

  test(
    'un saut de plus de 300 m est une correction : pas de trajet inventé',
    () {
      final m = MyPointMotion()
        ..setFix(50.6368, 3.0708, 2000, t0)
        // ~1,1 km plus loin : la position précise revient.
        ..setFix(50.6468, 3.0708, 15, t0.add(ms(1000)));
      final f = m.frameAt(t0.add(ms(1000)))!;
      expect(f.lat, 50.6468);
      expect(f.accuracy, 15);
    },
  );

  test('la flèche passe de 350° à 10° par le nord, jamais par le sud', () {
    final m = MyPointMotion()..setFix(50.6368, 3.0708, 20, t0);
    m.setHeading(350);
    expect(m.frameAt(t0)!.heading, 350);
    m.setHeading(10);
    var t = t0;
    for (var i = 0; i < 40; i++) {
      t = t.add(ms(16));
      final h = m.frameAt(t)!.heading!;
      // Toujours dans l'arc court [350, 360) ∪ [0, 10].
      expect(h >= 349.9 || h <= 10.1, isTrue, reason: 'cap $h');
    }
    expect(m.frameAt(t.add(ms(16)))!.heading!, closeTo(10, 0.5));
    expect(m.settledAt(t.add(ms(16))), isTrue);
  });

  test('sans boussole, pas de flèche', () {
    final m = MyPointMotion()
      ..setFix(50.6368, 3.0708, 20, t0)
      ..setHeading(90)
      ..setHeading(null);
    expect(m.frameAt(t0.add(ms(16)))!.heading, isNull);
  });

  test(
    '« recentrer » vise exactement le point dessiné, même en plein glissement',
    () {
      final m = MyPointMotion()
        ..setFix(50.6368, 3.0708, 20, t0)
        ..setFix(50.6369, 3.0708, 20, t0.add(ms(1000)));
      final t = t0.add(ms(1400));
      final vise = m.positionAt(t)!;
      final dessine = m.frameAt(t)!;
      expect(vise.lat, dessine.lat);
      expect(vise.lon, dessine.lon);
    },
  );
}
