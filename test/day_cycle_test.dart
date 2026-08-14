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
    // 3 minutes il se déplace à 21,8 h, qui est le vrai segment le plus rapide
    // (Lavender Dusk → Deep Forest). La fenêtre laisse le signal dominer le
    // bruit d'arrondi.
    //
    // 3 minutes = une session réaliste. Le seuil de 0,02 est l'écart
    // **juste perceptible côte à côte** en OkLab : on exige donc qu'une session
    // entière change moins que ce que l'œil distingue avec les deux couleurs
    // sous les yeux en même temps — alors qu'ici il n'a aucune référence.
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
          'Deux ancrages voisins sont soit trop éloignés en couleur, soit trop '
          'proches en heure — écarter les heures suffit en général, la journée '
          'a de la marge.',
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
