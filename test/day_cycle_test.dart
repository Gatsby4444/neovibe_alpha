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

  test('l\'accent reste lisible sous du texte blanc, à chaque minute', () {
    var worst = double.infinity;
    var worstAt = 0.0;
    for (final h in everyMinute()) {
      final ratio = contrastRatio(DayCycle.at(h).accent, white);
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
  });

  test('le fond ne change pas visiblement pendant une session', () {
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
      final a = DayCycle.at(m / 60);
      final b = DayCycle.at((m + sessionMinutes) / 60);
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

  test('la bande médiane est bien plus colorée que la moyenne', () {
    // Sinon le troisième arrêt ne servirait à rien : il tomberait pile sur la
    // droite qui joint les deux autres, et le dégradé serait identique à deux
    // arrêts. C'est le renflement qui donne sa matière au fond.
    var bowed = 0;
    for (final h in everyMinute()) {
      final p = DayCycle.at(h);
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

  test('le cycle boucle sans couture à minuit', () {
    final before = DayCycle.at(23.9999);
    final after = DayCycle.at(0.0001);
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

  test('aucun segment ne fabrique un creux terne en son milieu', () {
    // ### Ce que ce test protège, et pourquoi il vaut plus qu'il n'en a l'air
    //
    // C'est la propriété obtenue le 2026-08-15 en passant à l'arc de teinte
    // (`_Lab.lerpArcPair`), et validée à l'œil par Jay.
    //
    // L'ancienne interpolation était une **corde** dans le plan (a, b) : une
    // ligne droite, qui passe donc près du CENTRE de la roue des couleurs —
    // c'est-à-dire près du gris — dès que deux palettes voisines ont des
    // teintes opposées. Résultat : un milieu de segment plus terne que ses
    // DEUX extrémités, alors qu'aucune des deux palettes n'est terne.
    //
    // Mesuré sur les ancrages du jour : pire ratio **0,37 avec la corde**,
    // **0,83 avec l'arc** (et 11 segments sur 12 à 1,00 ou mieux).
    //
    // ⚠️ Ce test échouerait si quelqu'un remettait `_Lab.lerp` sur le chemin
    // temporel — et c'est tout l'intérêt : le retour en arrière serait
    // **invisible au diff** (une lettre) et invisible à l'exécution, sauf à
    // regarder l'app à la bonne heure.
    const floorRatio = 0.80;

    double meanChroma(DayPalette p) =>
        (chromaOf(p.top) + chromaOf(p.middle) + chromaOf(p.bottom)) / 3;

    final anchors = DayCycle.anchors;
    for (var i = 0; i < anchors.length - 1; i++) {
      final a = anchors[i];
      final b = anchors[i + 1];
      final ends = [
        meanChroma(DayCycle.at(a.hour)),
        meanChroma(DayCycle.at(b.hour - 1e-9)),
      ].reduce((x, y) => x < y ? x : y);

      var lowest = double.infinity;
      var lowestAt = a.hour;
      for (var s = 1; s < 100; s++) {
        final h = a.hour + (b.hour - a.hour) * s / 100;
        final c = meanChroma(DayCycle.at(h));
        if (c < lowest) {
          lowest = c;
          lowestAt = h;
        }
      }

      expect(
        lowest,
        greaterThanOrEqualTo(ends * floorRatio),
        reason:
            'Le trajet ${a.label} → ${b.label} devient terne en son milieu : '
            'chroma ${lowest.toStringAsFixed(3)} à '
            '${lowestAt.toStringAsFixed(2)} h, contre '
            '${ends.toStringAsFixed(3)} à la plus terne de ses bornes. '
            'Le gris est fabriqué par le CHEMIN, pas par les palettes — '
            'vérifier que _Lab.lerpArcPair est bien utilisée dans DayCycle.at.',
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
