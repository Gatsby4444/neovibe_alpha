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
  static const requestsSent = 'demandes émises';
  static const requestsReceived = 'demandes reçues';
  static const accepted = 'demandes acceptées';
  static const declined = 'demandes refusées';
  static const friendsPulled = 'synchros du carnet réussies';

  static final instance = EventTrace(
    'connexions',
    counters: [
      requestsSent,
      requestsReceived,
      accepted,
      declined,
      friendsPulled,
    ],
  );

  static void count(String kind) => instance.count(kind);

  static void note(String kind, {String? subject, String? detail}) =>
      instance.note(kind, subject: subject ?? '—', detail: detail);

  static String report() => instance.report();
}

/// Les motifs consignés, nommés une seule fois.
abstract final class ConnectionEvent {
  /// Une demande a été émise vers quelqu'un qui est **déjà un ami**.
  ///
  /// Ne devrait plus arriver : le bouton ne s'affiche plus dans ce cas depuis
  /// que le statut se dérive du carnet. S'il bouge, c'est que l'interface et le
  /// carnet ont recommencé à diverger — exactement le défaut du 2026-08-17.
  static const requestToFriend = 'demande vers un ami déjà connecté';

  /// Une demande **reçue** de quelqu'un qui est déjà un ami. Ignorée.
  static const requestFromFriend = 'demande reçue d\'un ami déjà connecté';

  /// La signature de la demande n'est pas valide — la demande est jetée.
  static const badSignature = 'signature de demande invalide';

  /// Une **acceptation** reçue ne correspond à aucune demande de notre part.
  ///
  /// ⚠️ **Le motif le plus important de cette liste.** Il ne devrait jamais
  /// bouger. S'il bouge, quelqu'un essaie de se faire passer pour un ami
  /// accepté — voir `_onFriendAccept`.
  static const acceptNotOurs = 'acceptation sans demande de notre part';

  /// La demande ne nous est pas adressée, ou son émetteur ne correspond pas au
  /// pair qui l'apporte.
  static const notForUs = 'demande mal adressée';

  /// L'acceptation n'a pas pu partir : le pair n'était plus joignable. **La
  /// demande reste**, elle sera rejouable.
  static const acceptUndeliverable = 'acceptation non remise';

  /// Le carnet a changé : le réseau reconstruit son index rotatif.
  static const bookChanged = 'carnet modifié';

  /// La synchronisation a retiré des amis que le serveur ne renvoie plus.
  static const friendsRemoved = 'amis retirés du carnet';

  /// La synchronisation n'a pas pu joindre le serveur.
  static const syncOffline = 'synchronisation hors ligne';

  /// Un élément de la file d'envoi a été abandonné définitivement.
  static const outboxAbandoned = 'élément de file abandonné';
}
