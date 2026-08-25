import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **Le temps est une SOURCE comme une autre — il s'acquiert, il ne se devine
/// pas au passage.**
///
/// ## Le problème que ce fichier supprime
///
/// Un provider qui filtre sur `DateTime.now()` ne se recalcule que lorsque **sa
/// source** change. Sa valeur dépend pourtant d'une seconde source — l'heure —
/// qu'il consulte sans jamais s'y abonner. Conséquence : la donnée périme à
/// l'écran et **personne ne s'en aperçoit**, jusqu'à ce qu'un événement sans
/// rapport passe par là.
///
/// Ce défaut a été signalé par Jay **deux fois**, à deux endroits différents :
/// le 2026-07-13 sur les messages (« disparition buggée »), et il était encore
/// présent sur les connexions partielles au 2026-08-25.
///
/// ## Pourquoi une horloge partagée plutôt qu'une minuterie par endroit
///
/// La première correction (2026-07-13) avait posé un `Timer.periodic(10 s)`
/// **dans la couche d'acquisition** des messages, qui réémettait toute la liste.
/// Elle imposait donc son rythme à tous les lecteurs du flux — 360 réveils par
/// heure, chat ouvert et inactif — et un futur second lecteur en aurait hérité
/// sans l'avoir demandé.
///
/// Ici le rythme appartient au **consommateur** : il choisit sa période, et
/// c'est tout ce qu'il obtient. Surtout, un tic ne traverse pas : le
/// consommateur recalcule sa liste, et [DerivedList] arrête net la propagation
/// tant que le RÉSULTAT est identique. L'horloge bat, l'écran ne bouge pas —
/// jusqu'à la seconde où quelque chose expire vraiment.
///
/// ⚠️ **Choisir la période la plus GROSSIÈRE qui tienne la promesse produit.**
/// Une expiration qu'on peut voir disparaître avec 5 s de retard n'a aucune
/// raison d'être vérifiée toutes les 100 ms.
final tickProvider = StreamProvider.family<DateTime, Duration>((ref, period) {
  // Une première valeur immédiatement : sans elle, tout ce qui dépend du temps
  // attendrait une période entière avant d'exister — et afficherait donc, le
  // temps d'un battement, exactement ce qu'on cherche à masquer.
  return Stream<DateTime>.multi((controller) {
    controller.add(DateTime.now());
    final timer = Timer.periodic(period, (_) => controller.add(DateTime.now()));
    controller.onCancel = timer.cancel;
  });
});

/// La période retenue pour tout ce qui expire à l'échelle de la minute
/// (connexions partielles, messages éphémères, stories).
///
/// ⚠️ **Une seule constante pour tout le produit.** Deux endroits qui vérifient
/// la même sorte de péremption à deux rythmes différents finiraient par
/// s'afficher en désaccord, et rien ne le signalerait.
const kExpiryTick = Duration(seconds: 5);

/// L'heure courante, arrondie à [kExpiryTick], pour ce qui périme.
final expiryClockProvider = Provider<DateTime>((ref) {
  return ref.watch(tickProvider(kExpiryTick)).value ?? DateTime.now();
});
