import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/distance_estimate.dart';

void main() {
  group('la fourchette dit la vérité sur son imprécision', () {
    test('elle est LARGE, et c est le fait le plus important', () {
      final e = DistanceModel.estimate(
        smoothedRssi: -70,
        txPower: -7,
        currentBand: null,
        trend: ProximityTrend.stable,
      );

      // Le rapport entre les deux bornes est ce qui condamne un affichage en
      // metres : il ne descend jamais en dessous d'un facteur ~4.
      final rapport = e.maxMeters / e.minMeters;
      expect(
        rapport,
        greaterThan(3.5),
        reason: 'une fourchette etroite serait un mensonge',
      );
      expect(e.calibrated, isTrue);
    });

    test('sans puissance annoncee, on le DIT', () {
      final e = DistanceModel.estimate(
        smoothedRssi: -70,
        txPower: 127, // non annoncee
        currentBand: null,
        trend: ProximityTrend.stable,
      );
      expect(e.calibrated, isFalse);
    });

    test('plus le signal est fort, plus la distance est courte', () {
      double centre(double rssi) {
        final e = DistanceModel.estimate(
          smoothedRssi: rssi,
          txPower: -7,
          currentBand: null,
          trend: ProximityTrend.stable,
        );
        return (e.minMeters + e.maxMeters) / 2;
      }

      expect(centre(-50), lessThan(centre(-70)));
      expect(centre(-70), lessThan(centre(-90)));
    });
  });

  group('les bandes', () {
    test('un signal fort donne le contact, un signal faible donne loin', () {
      expect(DistanceModel.bandFor(-40, null), ProximityBand.contact);
      expect(DistanceModel.bandFor(-95, null), ProximityBand.far);
    });

    test('l hysteresis empeche le clignotement a la frontiere', () {
      // On entre en « contact » a -55.
      var bande = DistanceModel.bandFor(-50, null);
      expect(bande, ProximityBand.contact);

      // On repasse JUSTE sous le seuil d'entree : sans hysteresis, ca
      // basculerait. Avec, il faut descendre de 6 dB de plus.
      bande = DistanceModel.bandFor(-58, bande);
      expect(bande, ProximityBand.contact, reason: 'la marge doit tenir');

      // Au-dela de la marge, on descend.
      bande = DistanceModel.bandFor(-64, bande);
      expect(bande, ProximityBand.close);
    });
  });

  group('la tendance', () {
    test('un signal qui monte franchement = se rapproche', () {
      expect(
        DistanceModel.trendFor(-80, -68, const Duration(seconds: 3)),
        ProximityTrend.approaching,
      );
    });

    test('un signal qui descend franchement = s eloigne', () {
      expect(
        DistanceModel.trendFor(-60, -75, const Duration(seconds: 3)),
        ProximityTrend.leaving,
      );
    });

    test('une derive lente reste STABLE', () {
      // Un appareil immobile derive facilement de 1 dB/s sans que personne
      // n'ait bouge : au-dessous du seuil, on ne raconte rien.
      expect(
        DistanceModel.trendFor(-70, -73, const Duration(seconds: 3)),
        ProximityTrend.stable,
      );
    });

    test(
      'LA propriete qui justifie la tendance : un obstacle fixe ne change pas '
      'le signe de la pente',
      () {
        // Meme marche d'approche, mais avec un corps qui absorbe 15 dB en
        // permanence. Les DEUX mesures sont decalees de la meme quantite.
        const absorption = -15.0;
        final sans = DistanceModel.trendFor(
          -80,
          -68,
          const Duration(seconds: 3),
        );
        final avec = DistanceModel.trendFor(
          -80 + absorption,
          -68 + absorption,
          const Duration(seconds: 3),
        );

        // C'est tout l'interet : la distance absolue serait fausse d'un facteur
        // 4, la tendance reste juste.
        expect(avec, sans);
        expect(avec, ProximityTrend.approaching);
      },
    );

    test('une duree nulle ne raconte rien', () {
      expect(
        DistanceModel.trendFor(-80, -50, Duration.zero),
        ProximityTrend.stable,
      );
    });
  });

  group('l ANCRAGE ABSOLU - le test qui manquait', () {
    // ⚠️ Le 2026-08-16, deux appareils a moins d'un metre affichaient
    // « entre 40 et 140 m ». Tous les tests passaient : ils ne verifiaient que
    // des proprietes RELATIVES, et une erreur d'ECHELLE les traverse sans les
    // faire broncher. Ces trois-la ancrent la valeur absolue.

    test('un RSSI typique de UN METRE rend environ un metre', () {
      // -48 dBm est ce qu'on lit a 1 m d'un emetteur a -7 dBm.
      final e = DistanceModel.estimate(
        smoothedRssi: -48,
        txPower: -7,
        currentBand: null,
        trend: ProximityTrend.stable,
      );
      expect(e.meters, closeTo(1.0, 0.3));
    });

    test(
      'deux appareils cote a cote ne sont JAMAIS a des dizaines de metres',
      () {
        // Le cas exact rapporte par Jay : appareils a moins d'un metre.
        for (final rssi in [-40.0, -45.0, -50.0, -55.0]) {
          final e = DistanceModel.estimate(
            smoothedRssi: rssi,
            txPower: -7,
            currentBand: null,
            trend: ProximityTrend.stable,
          );
          expect(
            e.meters,
            lessThan(5),
            reason: 'a $rssi dBm on est dans la meme piece, pas a un carrefour',
          );
        }
      },
    );

    test('un signal faible rend bien une grande distance', () {
      final e = DistanceModel.estimate(
        smoothedRssi: -95,
        txPower: -7,
        currentBand: null,
        trend: ProximityTrend.stable,
      );
      expect(e.meters, greaterThan(20));
    });
  });
}
