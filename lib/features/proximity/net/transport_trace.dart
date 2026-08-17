/// Le journal des PERTES du transport de proximité.
///
/// ## Pourquoi ce fichier existe
///
/// Le 2026-08-16, Jay a clôturé une journée de tests sur : *« globalement cela
/// fonctionne mais il y a encore des messages fantômes perdus, je ne sais pas
/// pourquoi »*. Deux causes ont été trouvées et corrigées ce jour-là, une
/// troisième le lendemain — mais **aucun des rapports envoyés depuis les
/// appareils ne pouvait aider** : la section proximité ne contenait que le
/// nombre d'annonces reçues. Ni les canaux remplacés, ni les déchiffrements
/// refusés, ni les trames arrivées sur un lien sans canal.
///
/// *Un rapport ne peut pas dire ce que le code ne consigne pas.* On l'a payé
/// trois fois dans la même journée.
///
/// ## Ce qu'il consigne, et rien d'autre
///
/// **Les endroits où une trame disparaît sans que personne ne lève.** Ce sont
/// exactement les points où le code fait `return` sans un mot — et chacun est
/// un candidat message fantôme. Un envoi qui échoue avec une erreur, lui, n'a
/// pas besoin d'être ici : il se voit déjà.
///
/// ⚠️ **Aucun contenu de message n'y entre.** Un motif, une adresse de lien, un
/// nombre d'octets — rien de plus. Le journal part dans les rapports de
/// développement, et « ce qui se passe sur NeoVibe reste sur NeoVibe » vaut
/// aussi pour nos propres outils.
///
/// ⚠️ **Statique volontairement.** Les [PeerNetwork] et les [PeerLink] naissent
/// et meurent au gré des liens ; un journal porté par eux disparaîtrait avec
/// l'objet dont il faut justement expliquer la mort.
library;

/// Une perte, telle qu'elle s'est produite.
class TransportDrop {
  TransportDrop(this.kind, this.linkId, this.detail) : at = DateTime.now();

  /// Le motif, en quelques mots. Sert aussi de clé de comptage.
  final String kind;

  final String linkId;

  /// Ce qui distingue cette occurrence des autres du même motif.
  final String? detail;

  final DateTime at;

  @override
  String toString() {
    final h = at.toIso8601String().substring(11, 23);
    return '$h  $kind  ($linkId)${detail == null ? '' : ' — $detail'}';
  }
}

/// Le journal lui-même.
class TransportTrace {
  TransportTrace._();

  /// Assez pour couvrir une session de test de Jay, assez peu pour tenir dans
  /// un rapport lisible. Les pertes sont censées être RARES : si ce plafond est
  /// atteint, c'est déjà une information.
  static const capacity = 200;

  static final _drops = <TransportDrop>[];
  static final _counts = <String, int>{};

  /// Nombre de trames applicatives **livrées**, tous liens confondus.
  ///
  /// ⚠️ **C'est le dénominateur, et il est indispensable.** « 3 trames
  /// perdues » ne veut rien dire seul : sur 4 échangées c'est une panne, sur
  /// 4 000 c'est du bruit radio. Un compteur de pertes sans compteur de succès
  /// est un instrument qui ne peut pas contenir la preuve du contraire.
  static var delivered = 0;

  static void noteDelivered() => delivered++;

  static void drop(String kind, String linkId, [String? detail]) {
    _counts[kind] = (_counts[kind] ?? 0) + 1;
    _drops.add(TransportDrop(kind, linkId, detail));
    if (_drops.length > capacity) _drops.removeAt(0);
  }

  static List<TransportDrop> get drops => List.unmodifiable(_drops);

  static Map<String, int> get counts => Map.unmodifiable(_counts);

  static int get total => _counts.values.fold(0, (a, b) => a + b);

  static void clear() {
    _drops.clear();
    _counts.clear();
    delivered = 0;
  }

  /// Rendu pour le rapport de diagnostic.
  static String report() {
    if (_drops.isEmpty) {
      return 'trames applicatives livrées : $delivered\n'
          'aucune perte consignée.';
    }
    final buffer = StringBuffer()
      ..writeln('trames applicatives livrées : $delivered')
      ..writeln('pertes consignées           : $total');
    final tri = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in tri) {
      buffer.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
    }
    buffer.writeln('\n--- les ${_drops.length} dernières ---');
    for (final d in _drops) {
      buffer.writeln(d);
    }
    return buffer.toString();
  }
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
  /// sait aujourd'hui.
  static const duplicateLink = 'second lien ignoré';

  /// Une session a été fermée par l'entretien, pas par la radio.
  static const sessionDropped = 'session fermée par l\'entretien';
}
