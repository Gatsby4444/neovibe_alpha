import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/day_cycle.dart';

/// Le cycle de 24 h vérifié **minute par minute**.
///
/// ### Pourquoi ce test existe
///
/// Le thème NeoVibe change de couleur avec l'heure. Une retouche de palette
/// peut donc casser la lisibilité **à une heure précise seulement** — et
/// personne ne s'en apercevra le jour du changement, parce que personne
/// n'ouvre l'app à 7 h ce matin-là. On le découvrirait une semaine plus tard,
/// par hasard, ou jamais.
///
/// Ce test transforme « est-ce que j'ai cassé quelque chose ? » en réponse
/// automatique. **C'est lui qui garde une retouche de couleur à deux minutes
/// de travail** : sans lui, il faudrait repasser tous les écrans à la main à
/// chaque changement, et au troisième plus personne ne le ferait.
///
/// Il n'est possible que parce que la palette est une **fonction pure** de
/// l'heure : on peut donc l'échantillonner exhaustivement.
void main() {
  const white = Color(0xFFFFFFFF);

  // Les 1440 minutes de la journée.
  List<double> everyMinute() => [for (var m = 0; m < 1440; m++) m / 60];

  // ⚠️ Tout ce qui suit est vérifié pour les DEUX chemins de teinte, parce que
  // les deux sont livrés le temps que Jay tranche. Ne vérifier que le défaut
  // laisserait l'autre casser en silence — et il est à un clic dans l'aperçu.
  for (final hue in HuePath.values) {
    test(
      '[${hue.label}] l\'accent reste lisible sous du blanc, chaque minute',
      () {
        var worst = double.infinity;
        var worstAt = 0.0;
        for (final h in everyMinute()) {
          final ratio = contrastRatio(DayCycle.at(h, hue: hue).accent, white);
          if (ratio < worst) {
            worst = ratio;
            worstAt = h;
          }
        }
        expect(
          worst,
          greaterThanOrEqualTo(DayCycle.accentMinContrast),
          reason:
              'Contraste insuffisant à ${worstAt.toStringAsFixed(2)} h '
              '(${worst.toStringAsFixed(2)}:1). Un ancrage de DayCycle.anchors '
              'rend l\'accent illisible à cette heure-là.',
        );
      },
    );
  }

  for (final hue in HuePath.values) {
    test('[${hue.label}] le fond ne change pas visiblement en session', () {
      // C'est l'énoncé mesurable de la demande de Jay : « comme le mouvement du
      // soleil, on remarque que cela change mais on ne le voit pas vraiment ».
      //
      // ### Pourquoi une FENÊTRE et pas une comparaison minute à minute
      //
      // La première version de ce test comparait deux minutes consécutives. Elle
      // échouait à 5 h — et pour une mauvaise raison : à cette heure le fond est
      // très sombre, et dans les tons sombres **un seul cran de quantification
      // 8 bits** pèse plus lourd en ΔE que le déplacement réel de la palette.
      // Le test mesurait donc la résolution de l'écran, pas la conception.
      //
      // Mesuré : à 1 minute le pire cas tombe à 5,27 h (quantification) ; dès
      // 3 minutes il se déplace sur le vrai segment le plus rapide. La fenêtre
      // laisse le signal dominer le bruit d'arrondi.
      //
      // 3 minutes = une session réaliste. Le seuil de 0,02 est l'écart
      // **juste perceptible côte à côte** en OkLab : on exige donc qu'une session
      // entière change moins que ce que l'œil distingue avec les deux couleurs
      // sous les yeux en même temps — alors qu'ici il n'a aucune référence.
      //
      // ⚠️ C'est ce test qui a refusé la première cadence du 2026-08-15 : le saut
      // `Jungle sombre → Desert` posé sur 1 h 30 donnait 0,0202. Deux ancrages
      // écartés d'une heure ont suffi. **Écarter les heures est presque toujours
      // la bonne correction** — la journée a ~13 h de marge.
      const sessionMinutes = 3;
      const justNoticeable = 0.02;

      var worst = 0.0;
      var worstAt = 0.0;
      for (var m = 0; m < 1440; m++) {
        final a = DayCycle.at(m / 60, hue: hue);
        final b = DayCycle.at((m + sessionMinutes) / 60, hue: hue);
        final drift = [
          perceptualDistance(a.top, b.top),
          perceptualDistance(a.middle, b.middle),
          perceptualDistance(a.bottom, b.bottom),
        ].reduce((x, y) => x > y ? x : y);
        if (drift > worst) {
          worst = drift;
          worstAt = m / 60;
        }
      }
      expect(
        worst,
        lessThan(justNoticeable),
        reason:
            'Le fond change visiblement en $sessionMinutes minutes vers '
            '${worstAt.toStringAsFixed(2)} h (ΔE ${worst.toStringAsFixed(4)}). '
            'Deux ancrages voisins sont soit trop éloignés en couleur, soit '
            'trop proches en heure — écarter les heures suffit en général, la '
            'journée a de la marge.',
      );
    });

    test('[${hue.label}] la bande médiane reste plus colorée que la moyenne', () {
      // Sinon le troisième arrêt ne servirait à rien : il tomberait pile sur la
      // droite qui joint les deux autres, et le dégradé serait identique à deux
      // arrêts. C'est le renflement qui donne sa matière au fond.
      var bowed = 0;
      for (final h in everyMinute()) {
        final p = DayCycle.at(h, hue: hue);
        final flat = Color.lerp(p.top, p.bottom, DayCycle.middleStop)!;
        if (perceptualDistance(p.middle, flat) > 0.01) bowed++;
      }
      expect(
        bowed,
        greaterThan(1400),
        reason:
            'La bande médiane se confond avec une simple moyenne : le troisième '
            'arrêt n\'apporte rien.',
      );
    });

    test('[${hue.label}] le cycle boucle sans couture à minuit', () {
      final before = DayCycle.at(23.9999, hue: hue);
      final after = DayCycle.at(0.0001, hue: hue);
      for (final pair in [
        [before.top, after.top],
        [before.middle, after.middle],
        [before.bottom, after.bottom],
      ]) {
        expect(
          perceptualDistance(pair[0], pair[1]),
          lessThan(0.004),
          reason: 'Le passage de 23h59 à 00h00 se voit.',
        );
      }
    });
  }

  test('l\'arc de teinte est bien plus coloré que la corde', () {
    // L'énoncé mesurable de ce que l'arc apporte — sans quoi « on a changé
    // l'interpolation » resterait une intention.
    //
    // Il vaut aussi comme garde-fou : si une future retouche de palette
    // annulait le gain, ce test le dirait au lieu de laisser croire que le
    // correctif du 2026-08-15 tient toujours.
    var chord = 0.0;
    var arc = 0.0;
    for (final h in everyMinute()) {
      final c = DayCycle.at(h, hue: HuePath.chord);
      final a = DayCycle.at(h, hue: HuePath.arc);
      // La chroma se lit comme la distance au gris de même clarté.
      chord += chromaOf(c.top) + chromaOf(c.middle) + chromaOf(c.bottom);
      arc += chromaOf(a.top) + chromaOf(a.middle) + chromaOf(a.bottom);
    }
    expect(
      arc / chord,
      greaterThan(1.10),
      reason:
          'L\'arc n\'apporte plus que ${((arc / chord - 1) * 100).round()} % '
          'de chroma. Soit les ancrages voisins ont désormais des teintes '
          'proches (auquel cas la corde suffit et HuePath peut disparaître), '
          'soit lerpArc a été cassé.',
    );
  });

  test('aux heures d\'ancrage, les deux chemins donnent la MÊME couleur', () {
    // C'est la propriété qui a permis de proposer l'arc à Jay sans lui
    // redemander de valider ses palettes : le chemin ne change que l'entre-deux.
    for (final a in DayCycle.anchors) {
      final chord = DayCycle.at(a.hour, hue: HuePath.chord);
      final arc = DayCycle.at(a.hour, hue: HuePath.arc);
      expect(
        perceptualDistance(chord.top, arc.top),
        lessThan(0.001),
        reason: 'Le haut diffère à ${a.hour} h (${a.label}).',
      );
      expect(
        perceptualDistance(chord.bottom, arc.bottom),
        lessThan(0.001),
        reason: 'Le bas diffère à ${a.hour} h (${a.label}).',
      );
    }
  });

  test('les heures hors bornes retombent dans la journée', () {
    expect(DayCycle.at(25).top, DayCycle.at(1).top);
    expect(DayCycle.at(-1).top, DayCycle.at(23).top);
  });

  test('les ancrages sont triés et couvrent la journée entière', () {
    final anchors = DayCycle.anchors;
    expect(anchors.first.hour, 0);
    expect(anchors.last.hour, 24);
    for (var i = 1; i < anchors.length; i++) {
      expect(
        anchors[i].hour,
        greaterThan(anchors[i - 1].hour),
        reason: 'DayCycle.anchors doit rester trié par heure croissante.',
      );
    }
  });
}
