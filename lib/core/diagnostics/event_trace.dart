/// Un journal d'événements RARES, avec son dénominateur.
///
/// ## Pourquoi ce fichier existe
///
/// Deux fois en deux jours, une panne signalée par Jay n'a pas pu être
/// instruite : le 2026-08-16 les messages fantômes, le 2026-08-17 les demandes
/// d'amis. Dans les deux cas les rapports envoyés depuis les appareils étaient
/// muets, pour la même raison — *un rapport ne peut pas dire ce que le code ne
/// consigne pas*.
///
/// La première fois, le journal du transport a été écrit à la main. Il a payé
/// **dès le relevé suivant** : il a réfuté une hypothèse de réécriture du natif
/// et révélé une quatrième cause de perte. On refait donc la même chose pour le
/// chemin des connexions — et une seule fois, ici.
///
/// ## Ce qu'il consigne, et rien d'autre
///
/// **Les endroits où quelque chose disparaît sans que personne ne lève.** Un
/// échec qui remonte une erreur se voit déjà ; il n'a pas besoin d'être ici.
///
/// ⚠️ **Aucun contenu utilisateur n'y entre.** Un motif, un identifiant, un
/// nombre — jamais un message, jamais un nom. Ces journaux partent dans les
/// rapports de développement.
library;

/// Un événement, tel qu'il s'est produit.
class TraceEvent {
  TraceEvent(this.kind, this.subject, this.detail) : at = DateTime.now();

  /// Le motif, en quelques mots. Sert aussi de clé de comptage.
  final String kind;

  /// À qui / à quoi ça s'est produit (adresse de lien, identifiant).
  final String subject;

  /// Ce qui distingue cette occurrence des autres du même motif.
  final String? detail;

  final DateTime at;

  @override
  String toString() {
    final h = at.toIso8601String().substring(11, 23);
    return '$h  $kind  ($subject)${detail == null ? '' : ' — $detail'}';
  }
}

/// Un anneau d'événements nommés, plus des compteurs.
///
/// ⚠️ **Instance nommée, jamais statique globale.** Deux domaines qui obéissent
/// aux mêmes règles peuvent partager le même code ; ils ne doivent pas partager
/// le même seau, sinon un rapport ne dit plus lequel des deux a bougé.
class EventTrace {
  EventTrace(this.name, {this.capacity = 200});

  /// Ce qui s'affiche en tête de section dans le rapport.
  final String name;

  /// Assez pour couvrir une session de test de Jay, assez peu pour tenir dans
  /// un rapport lisible. Les événements consignés sont censés être **rares** :
  /// si ce plafond est atteint, c'est déjà une information.
  final int capacity;

  final _events = <TraceEvent>[];
  final _counts = <String, int>{};
  final _totals = <String, int>{};

  /// Consigne un événement rare : il est **compté et daté**.
  void note(String kind, {String subject = '—', String? detail}) {
    _counts[kind] = (_counts[kind] ?? 0) + 1;
    _events.add(TraceEvent(kind, subject, detail));
    if (_events.length > capacity) _events.removeAt(0);
  }

  /// Compte un événement FRÉQUENT, sans le dater.
  ///
  /// ⚠️ **C'est le dénominateur, et il est indispensable.** « 3 pertes » ne veut
  /// rien dire seul : sur 4 échanges c'est une panne, sur 4 000 c'est du bruit.
  /// Un compteur d'échecs sans compteur de succès est un instrument qui ne peut
  /// pas contenir la preuve du contraire.
  void count(String kind) => _totals[kind] = (_totals[kind] ?? 0) + 1;

  int totalOf(String kind) => _totals[kind] ?? 0;

  List<TraceEvent> get events => List.unmodifiable(_events);

  Map<String, int> get counts => Map.unmodifiable(_counts);

  int get total => _counts.values.fold(0, (a, b) => a + b);

  void clear() {
    _events.clear();
    _counts.clear();
    _totals.clear();
  }

  /// Rendu pour le rapport de diagnostic.
  String report() {
    final buffer = StringBuffer();
    if (_totals.isEmpty && _events.isEmpty) return 'rien à signaler.';

    final totaux = _totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in totaux) {
      buffer.writeln('${e.key.padRight(28)} : ${e.value}');
    }

    if (_events.isEmpty) {
      buffer.writeln('aucun événement consigné.');
      return buffer.toString();
    }

    buffer.writeln('${'événements consignés'.padRight(28)} : $total');
    final tri = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in tri) {
      buffer.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
    }
    buffer.writeln('\n--- les ${_events.length} derniers ---');
    for (final e in _events) {
      buffer.writeln(e);
    }
    return buffer.toString();
  }
}
