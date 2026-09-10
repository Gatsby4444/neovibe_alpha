/// **Le DÉLAI du « presque », décidé par le palier d'amitié.**
///
/// ## 🔴 Il a changé de destinataire le 2026-08-30
///
/// Cette règle réglait le délai du **presque**. Elle ne le peut plus : depuis la
/// refonte des waves, un presque ne peut pas être décidé avant **une heure**
/// (`WaveRules.apresFenetre`), parce qu'il faut voir ce qui se passe *après* le
/// croisement pour savoir si on s'est vraiment ratés. Un délai de 45 minutes
/// posé sur une notification déjà en retard d'une heure ne se serait jamais vu :
/// les trois paliers auraient rendu **exactement le même résultat**, et rien ne
/// l'aurait signalé.
///
/// ⚠️ **Décision de Jay, 2026-08-30** : le palier déménage sur la notification
/// **instantanée** — *« ton ami est tout près »*.
///
/// ## 🔴 REVENU AU PRESQUE le 2026-09-01 — et l'argument de 2026-08-30 était faux
///
/// Jay, le 2026-09-01 : *« la notification dont je parlais pour ce système c'est
/// juste la notification du presque, uniquement si c'était un presque. Pas la
/// notif instantanée dans le cas où quelqu'un est tout près. C'est deux choses
/// différentes. […] la notif instantanée c'est pour tout le monde. »*
///
/// L'argument qui avait justifié le déménagement — *« un délai de 45 minutes
/// posé sur une notification déjà en retard d'une heure ne se serait jamais
/// vu : les trois paliers auraient rendu exactement le même résultat »* —
/// **est faux, et il a été vérifié à la source cette fois.** Le verdict du
/// presque est rendu par un balayage qui tourne toutes les **5 minutes**
/// (`ProximityController.verdictEvery`) : un presque d'inséparable part donc
/// vers 1 h 00, celui d'un ami simple vers 1 h 45. Les trois paliers donnent
/// bien trois résultats différents.
///
/// ⚠️ **La leçon** : l'argument avait été écrit dans un commentaire, jamais
/// re-vérifié, et il a décidé d'un déplacement de fonctionnalité. C'est
/// exactement ce que la règle « un fait se vérifie à la source » interdit.
///
/// ## Ce que ça change pour l'utilisateur
///
/// Avant le 2026-08-30, un seul interrupteur global décidait pour tout le
/// monde : ou bien tout arrivait tout de suite, ou bien tout arrivait plus tard.
/// Le premier réglage était bruyant, le second inutile pour les gens qui
/// comptent. Désormais **l'app te prévient tout de suite pour ceux dont tu es
/// proche**, et laisse passer un peu de temps pour les autres.
///
/// ⚠️ **Correction d'une imprécision de ma propre question à Jay**, consignée
/// pour ne pas la reproduire (`RAPPELS.md` #102) : je lui avais présenté ce
/// déblocage comme « aujourd'hui c'est un réglage global ». Vérifié ensuite dans
/// le code : `profiles.realtime_waves` n'est pas « qui peut me voir en direct »,
/// c'est **ma propre préférence sur mes propres notifications**. Ce n'était donc
/// pas un droit qu'on pouvait donner à quelqu'un d'autre.
///
/// ## Pourquoi une classe pure et pas trois lignes dans le contrôleur
///
/// Le contrôleur de proximité est la couche d'ACQUISITION. Lui faire porter une
/// règle sociale, c'est exactement ce que la consigne de Jay interdit : le ping
/// ne décide d'aucun palier. Ici il ne fait que passer une valeur qu'on lui a
/// donnée, et cette règle-ci se teste sans radio, sans réseau et sans disque.
abstract final class PresqueDelai {
  /// Le délai **ajouté** pour un ami sans palier particulier, par-dessus
  /// l'heure d'attente que le presque impose déjà par construction.
  static const ami = Duration(minutes: 45);

  /// Un proche : assez court pour être utile, assez long pour ne pas être un
  /// second ping.
  ///
  /// ⚠️ Valeur **raisonnée, pas mesurée** (2026-08-30).
  static const proche = Duration(minutes: 15);

  /// Un inséparable : tout de suite. C'est le privilège.
  static const inseparable = Duration.zero;

  /// Combien de temps attendre avant de signaler cette proximité.
  ///
  /// [tempsReelChoisi] est l'interrupteur de l'utilisateur (« Notifications en
  /// temps réel »). Quand il est allumé, il **force l'instantané pour tout le
  /// monde**.
  ///
  /// ⚠️ **Il l'emporte sur le palier, et jamais l'inverse.** Un réglage
  /// explicite qu'une règle automatique pourrait annuler n'est plus un réglage :
  /// l'utilisateur l'a mis à « tout de suite », il doit obtenir tout de suite.
  /// Les paliers ne servent qu'à ceux qui n'ont rien demandé.
  static Duration pour({
    required int rangDuPalier,
    required bool tempsReelChoisi,
  }) {
    if (tempsReelChoisi) return inseparable;
    return switch (rangDuPalier) {
      >= 2 => inseparable,
      1 => proche,
      _ => ami,
    };
  }
}
