import '../../../core/diagnostics/event_trace.dart';

/// Le journal du chemin des CONNEXIONS : demandes d'amis et synchronisation.
///
/// ## Pourquoi il existe
///
/// Le 2026-08-17, Jay a signalé une demande d'ami envoyée à quelqu'un dont il
/// était déjà ami, une confirmation « demande envoyée » sans rien en face, et un
/// encadré d'acceptation apparu bien plus tard. **Les deux rapports envoyés
/// depuis les appareils ne contenaient pas une seule ligne sur ce chemin** :
/// ni demande émise, ni demande reçue, ni signature refusée, ni synchronisation.
/// La séquence était irreconstituable.
///
/// C'était le même mal, au même endroit du raisonnement, que pour le transport
/// la veille — et le journal du transport avait déjà prouvé sa valeur au premier
/// relevé suivant.
///
/// ## Ce qu'il consigne
///
/// Les deux extrémités de chaque décision : **ce qui part**, **ce qui arrive**,
/// et **ce qui est refusé sans le dire**. Plus les compteurs de la
/// synchronisation, seule à savoir combien d'amis le serveur a réellement
/// renvoyés.
///
/// ⚠️ **Aucun nom, aucun contenu.** Des identifiants et des motifs.
abstract final class ConnectionTrace {
  /// Dénominateurs : ce qui s'est bien passé. **Toujours affichés, même à
  /// zéro** — un zéro mesuré et un seau vide ne se ressemblent que dans un
  /// rapport qui cache les zéros.
  /// ⚠️ **Quatre compteurs retirés le 2026-08-27** — `demandes émises`,
  /// `demandes reçues`, `demandes acceptées`, `demandes refusées`.
  ///
  /// Ils comptaient les demandes d'amis **co-signées en BLE**, qui n'existent
  /// plus : une demande est désormais une ligne de `connection_requests`, donc
  /// une question à poser au serveur, pas un compteur local.
  ///
  /// Les laisser aurait affiché **quatre zéros permanents** dans le rapport de
  /// diagnostic. Un compteur qui ne peut plus bouger n'est pas une mesure —
  /// c'est une invitation à conclure « aucune demande » là où il n'y a rien à
  /// compter.
  static const friendsPulled = 'synchros du carnet réussies';

  static final instance = EventTrace('connexions', counters: [friendsPulled]);

  static void count(String kind) => instance.count(kind);

  static void note(String kind, {String? subject, String? detail}) =>
      instance.note(kind, subject: subject ?? '—', detail: detail);

  static String report() => instance.report();
}

/// Les motifs consignés, nommés une seule fois.
abstract final class ConnectionEvent {
  // ⚠️ **Sept motifs retirés le 2026-08-27**, avec les demandes d'amis en BLE :
  // `requestToFriend`, `requestFromFriend`, `badSignature`, `acceptNotOurs`,
  // `notForUs`, `declineWithoutRequest` et `acceptUndeliverable`.
  //
  // ⚠️ **`acceptNotOurs` était le plus important de la liste** — il guettait
  // quelqu'un qui essaie de s'inscrire lui-même comme ami accepté, la barrière
  // fondatrice du produit. Ce qu'il surveillait est désormais tenu par le
  // serveur (`request_connection_from_proximity`, qui exige une paire mutuelle
  // fraîche), donc **ça ne se surveille plus ici — ça se surveille en base**.
  // À garder en tête : la surveillance n'a pas disparu, elle a changé d'endroit,
  // et cet endroit-là n'est pas dans le rapport de diagnostic de Jay.

  // ⚠️ `bookChanged` retiré le 2026-08-27 : il était **déjà** sans producteur
  // avant ce chantier (vérifié sur `HEAD~1`), donc jamais consigné par personne.

  /// La synchronisation a retiré des amis que le serveur ne renvoie plus.
  static const friendsRemoved = 'amis retirés du carnet';

  /// La synchronisation n'a pas pu joindre le serveur.
  static const syncOffline = 'synchronisation hors ligne';

  /// Un élément de la file d'envoi a été abandonné définitivement.
  static const outboxAbandoned = 'élément de file abandonné';
}
