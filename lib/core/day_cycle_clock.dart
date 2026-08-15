import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// L'heure courante, en heures décimales, rafraîchie chaque minute.
///
/// ### Pourquoi ce fichier est séparé de `day_cycle.dart`
///
/// `DayCycle.at` est une **fonction pure de l'heure**, et tout son intérêt en
/// dépend : c'est ce qui la rend testable exhaustivement (les 1440 minutes).
/// Elle ne doit donc jamais lire l'horloge elle-même — sinon un test devrait
/// se déguiser en 5 h du matin pour vérifier 5 h du matin.
///
/// Le temps est une **entrée**, apportée d'ici. C'est la seule chose que ce
/// fichier fait.
///
/// ### Pourquoi une minute, et pas une seconde
///
/// Le cycle est conçu pour être imperceptible : la journée entière tient dans
/// ~14 h de « budget » au rythme du juste-perceptible, donc en une minute la
/// couleur bouge **moins qu'un cran de quantification 8 bits** dans les tons
/// sombres. Rafraîchir plus souvent redessinerait l'écran pour rendre
/// exactement les mêmes octets.
///
/// ⚠️ Ne pas « améliorer » en passant à la seconde : ce serait du travail pur
/// pour zéro pixel changé, sur une app caméra-first où chaque image compte.
final currentHourProvider = StreamProvider<double>((ref) {
  double now() {
    final t = DateTime.now();
    return t.hour + t.minute / 60 + t.second / 3600;
  }

  // Une première valeur tout de suite : sans elle, le fond attendrait une
  // minute avant d'exister, et l'app s'ouvrirait sur la couleur de repli.
  return Stream<double>.multi((c) {
    c.add(now());
    final timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => c.add(now()),
    );
    c.onCancel = timer.cancel;
  });
});
