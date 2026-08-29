/// **La mémoire des présences en cours, et la seule question qu'on lui pose :**
/// *« celle qui vient de se terminer était-elle un « presque » ? »*
///
/// ## 🔴 Le défaut que cette classe supprime — signalé par Jay le 2026-08-29
///
/// > *« le presque se déclenche alors que je reste à proximité, il n'y a pas de
/// > croisement et pourtant le presque semble se déclencher à certains moments
/// > sans raisons apparentes »*
///
/// Le « presque » partait sur `PeerIdentified` — **au moment où l'on reconnaît
/// quelqu'un** — avec pour seule condition un délai de garde de deux heures.
/// Rien ne vérifiait que la personne soit repartie, ni qu'il n'y ait pas eu de
/// vrai croisement. Rester assis à côté d'un ami toute la journée en produisait
/// donc un : il suffisait que la radio hoquette une fois.
///
/// ## Ce qu'un « presque » veut dire, et ce qu'il ne veut pas dire
///
/// | | |
/// |---|---|
/// | ✅ *« vous vous êtes ratés »* | une présence **terminée**, trop brève pour compter |
/// | ❌ *« je viens de te reconnaître »* | ce que le code disait jusqu'au 2026-08-29 |
///
/// ## ⚠️ Pourquoi il n'y a pas de seuil ici
///
/// « Assez long pour compter » est déjà défini **une fois**, par
/// `PeerSession.isStable` — celui-là même qui décide d'un constat de croisement.
/// Cette mémoire ne fait donc qu'enregistrer un fait déjà établi ailleurs :
/// *cette présence a produit un constat*. Un second seuil aurait fait deux
/// définitions du même mot, qui auraient fini par se contredire sans que rien
/// ne le signale.
///
/// ## ⚠️ Classe pure
///
/// Aucun réseau, aucun disque, aucun Riverpod, aucune horloge : elle décide, et
/// c'est tout ce qu'elle fait. C'est ce qui la rend éprouvable
/// (`test/presque_test.dart`) — la version précédente de cette règle vivait
/// dans un `switch` au milieu du contrôleur, et n'était testée par rien.
class PresqueLedger {
  /// Les personnes dont la présence **en cours** a déjà produit un constat.
  final _croises = <String>{};

  /// ⚠️ **Point d'observation de test**, et il a une raison d'être : ce défaut
  /// ne lève rien et ne s'affiche nulle part — il ne se voit qu'en comptant ce
  /// qui reste en mémoire.
  int get length => _croises.length;

  /// Cette présence a produit un constat : ce ne sera pas un « presque ».
  ///
  /// ⚠️ **Appelé à chaque balayage, pas seulement au premier constat.** La
  /// question n'est pas « faut-il envoyer ce constat au serveur ? » — le journal
  /// des constats déduplique déjà par créneau — mais « cette présence a-t-elle
  /// compté ? ». Deux questions différentes, deux endroits.
  void noteCroisement(String userId) => _croises.add(userId);

  /// La présence de [userId] se termine. Rend `true` si c'était un « presque ».
  ///
  /// ⚠️ **Consomme l'entrée, dans les deux cas.** Cette mémoire décrit **une
  /// présence**, pas une personne : la garder au-delà ferait taire à tort le
  /// « presque » d'une vraie rencontre brève, plus tard, avec le même ami.
  bool finDePresence(String userId) => !_croises.remove(userId);

  /// La radio s'est arrêtée : plus aucune présence n'est en cours.
  ///
  /// ⚠️ **Ce n'est pas la même chose que des gens qui partent.** Couper sa
  /// visibilité n'émet aucun `PeerLost` — sans cet oubli, les entrées
  /// resteraient là pour toujours, et le premier vrai « presque » d'après serait
  /// avalé en silence.
  void oublieTout() => _croises.clear();
}
