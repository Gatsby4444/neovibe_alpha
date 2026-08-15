import 'package:flutter/material.dart';

import 'day_cycle.dart';
import 'motion.dart';

/// Le fond du thème NeoVibe : le dégradé du cycle de 24 h, à l'heure donnée.
///
/// ### Pourquoi ce widget vit dans `core/` et non près de l'aperçu
///
/// Il y est né (dans l'écran d'aperçu développeur) tant qu'il n'avait qu'un
/// usage de test. Depuis le 2026-08-15 il est **le fond de l'app entière**,
/// posé une fois dans `MaterialApp.builder`.
///
/// ⚠️ Le laisser dans `features/settings/sections/` aurait fait de la
/// suppression du dossier Développeur — prévue avant la prod, `RAPPELS.md`
/// ligne 4 — une **panne** : l'app aurait perdu son fond en supprimant un outil
/// de diagnostic. C'est le sens sortant de la règle de suppression, vérifié
/// avant de brancher plutôt qu'après.
class DayCycleBackground extends StatelessWidget {
  const DayCycleBackground({super.key, required this.hour, this.child});

  final double hour;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = DayCycle.at(hour);
    return AnimatedContainer(
      // Le fond ne s'anime pas « vers » une nouvelle couleur : il EST la
      // couleur de l'instant. Cette durée ne sert qu'aux rebuilds ponctuels
      // (retour d'arrière-plan, changement de thème), pour qu'ils ne sautent
      // pas. Le pas d'une minute de l'horloge est, lui, sous le seuil de
      // perception — il n'a rien à lisser.
      duration: NeoMotion.ample,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.top, p.middle, p.bottom],
          stops: const [0, DayCycle.middleStop, 1],
        ),
      ),
      child: child,
    );
  }
}
