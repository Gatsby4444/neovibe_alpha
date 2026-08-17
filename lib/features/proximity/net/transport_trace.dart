import '../../../core/diagnostics/event_trace.dart';

/// Le journal des PERTES du transport de proximité.
///
/// ## Ce qu'il a déjà payé
///
/// Écrit le 2026-08-17 au matin, il a servi **au premier relevé** :
///
/// - il a **réfuté** l'hypothèse des deux connexions GATT sous une même adresse
///   (`bothPathsPeak: 0` sur les deux appareils), donc évité une réécriture du
///   natif fondée sur une déduction ;
/// - il a **révélé** une quatrième cause de message fantôme, invisible
///   autrement : une session fermée par la fusion d'adresses d'un côté, un
///   `déchiffrement refusé` aux compteurs 0 et 1 de l'autre — la signature
///   d'une session neuve que le pair avait reconstruite et que nous refusions
///   d'adopter.
///
/// ## Ce qu'il consigne
///
/// **Les endroits où une trame disparaît sans que personne ne lève.** Ce sont
/// exactement les points où le code fait `return` sans un mot, et chacun est un
/// candidat message fantôme. Un envoi qui échoue avec une erreur, lui, se voit
/// déjà.
///
/// ⚠️ **Aucun contenu de message n'y entre.** Un motif, une adresse de lien, un
/// nombre d'octets — rien de plus.
abstract final class TransportTrace {
  static final instance = EventTrace('transport');

  /// Trames applicatives **livrées** — le dénominateur.
  static const delivered = 'trames applicatives livrées';

  static void noteDelivered() => instance.count(delivered);

  static void drop(String kind, String linkId, [String? detail]) =>
      instance.note(kind, subject: linkId, detail: detail);

  static String report() => instance.report();
}

/// Les motifs, nommés une seule fois.
///
/// ⚠️ Des chaînes libres au point d'appel produiraient « canal absent » et
/// « pas de canal » dans le même rapport, comptés séparément — et deux moitiés
/// de compteur ne prouvent rien.
abstract final class DropKind {
  /// Une trame est arrivée sur un lien qui n'a **aucun canal**.
  ///
  /// C'est la signature du message fantôme : l'émetteur a réussi son envoi, le
  /// destinataire avait déjà démonté la session.
  static const noChannel = 'trame sur un lien sans canal';

  /// Les octets ne forment pas une trame connue.
  static const undecodable = 'trame illisible';

  /// Le canal a refusé : mauvaise clé, compteur rejoué, ou octets modifiés.
  static const decryptRefused = 'déchiffrement refusé';

  /// Un message applicatif est arrivé avant le profil : on ne sait pas de qui.
  static const beforeProfile = 'message reçu avant le profil';

  /// Le traitement d'une trame a levé — le lien est refermé.
  static const handlerFailed = 'traitement de trame en échec';

  /// Le réassembleur a jeté ce qu'il tenait.
  static const reassembly = 'réassemblage abandonné';

  /// Un second lien vers un pair déjà relié a été ignoré.
  ///
  /// Pas une perte en soi — mais le compter dit à quel point le cas des deux
  /// connexions simultanées est fréquent sur le terrain, ce que personne ne
  /// savait avant le 2026-08-17.
  static const duplicateLink = 'second lien ignoré';

  /// Une session a été fermée par l'entretien, pas par la radio.
  static const sessionDropped = 'session fermée par l\'entretien';
}
