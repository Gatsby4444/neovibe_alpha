/// Ce qui a été **décidé** à l'ouverture d'une Vibe, et ce qui s'est
/// **réellement passé** ensuite.
///
/// ### Pourquoi cet outil existe
///
/// Les règles d'une Vibe — nombre de visionnages, durée par face, replay,
/// destruction — sont appliquées à **trois endroits différents** : le serveur
/// (`open_card_media`, qui vérifie et décompte dans une seule transaction),
/// l'écran de lecture (qui décide d'afficher, de refuser ou de couper), et le
/// budget de temps par face. Rien ne garantit que les trois racontent la même
/// histoire, et **un désaccord ne se voit pas** : l'écran affiche simplement
/// quelque chose de plausible.
///
/// Demande de Jay le 2026-08-13 : « des outils développeurs spécifiques
/// permettant de voir pour une card ses règles et de comparer avec mes actions
/// et ce que je vois, pour vérifier si elles sont respectées ».
///
/// L'idée est donc de mettre côte à côte, pour chaque ouverture :
/// **ce que le serveur dit · ce que l'écran a décidé · ce qui s'est passé**.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (voir `RAPPELS.md`, avant-prod #4).
library;

/// Un événement observé pendant une lecture.
class CardRuleEvent {
  CardRuleEvent(this.label, {this.detail}) : at = DateTime.now();

  final String label;
  final String? detail;
  final DateTime at;
}

/// Une ouverture de Vibe, du chargement à la fermeture de l'écran.
class CardRulesTrace {
  CardRulesTrace._(this.cardId, this.cardType) : _start = DateTime.now();

  static final _records = <CardRulesTrace>[];
  static const _maxRecords = 20;

  /// Vrai quand l'instrument tourne. Coupé, tout devient sans effet.
  static var enabled = true;

  final String cardId;
  final String cardType;
  final DateTime _start;

  // --- Ce que le SERVEUR dit ------------------------------------------

  /// Règles portées par la Vibe elle-même.
  int? maxViews;
  int? viewDurationSeconds;
  bool? saveable;
  bool? scrubbable;
  bool? encrypted;

  /// État de MA livraison, tel que lu au chargement.
  int? viewCountBefore;
  bool? destroyed;
  bool? replayGranted;

  /// État relu à la fermeture — c'est lui qui dit si le décompte a bien eu
  /// lieu, et **une seule fois**.
  int? viewCountAfter;

  // --- Ce que l'ÉCRAN a décidé ----------------------------------------

  /// Les limites s'appliquent-elles ? Faux pour l'auteur et en bibliothèque.
  bool? limitsApply;

  /// La phase retenue : `viewing`, `exhausted`, `destroyed`, `error`.
  String? phase;

  /// Visionnages restants calculés côté client, avant ouverture.
  int? remainingBefore;

  // --- Ce qui s'est PASSÉ ---------------------------------------------

  final events = <CardRuleEvent>[];

  /// Temps réellement passé sur chaque face, en millisecondes.
  final faceMs = <String, int>{};

  Duration get elapsed => DateTime.now().difference(_start);

  /// Ce que le décompte serveur a bougé pendant cette ouverture.
  ///
  /// **La valeur attendue est 1** — une ouverture consomme une vue, et une
  /// seule. `0` signale que le décompte n'a pas eu lieu (la limite ne serait
  /// alors pas une garantie) ; `2` qu'il a eu lieu deux fois (le cas que
  /// `card_viewer_screen.dart:241` évite explicitement en ne rappelant pas
  /// `markViewed` sur une Vibe chiffrée).
  int? get consumed => viewCountBefore == null || viewCountAfter == null
      ? null
      : viewCountAfter! - viewCountBefore!;

  /// L'ouverture a-t-elle été **refusée** parce que le budget était déjà
  /// épuisé ? Aucune clé n'est alors demandée, donc aucune vue consommée.
  bool get refusedAsExhausted => phase == 'exhausted';

  /// Le décompte s'est-il comporté comme annoncé ?
  ///
  /// Nul quand la question ne se pose pas (auteur, bibliothèque, ou état non
  /// relu).
  ///
  /// ⚠️ **Deux attentes, pas une** — corrigé le 2026-08-13 après un faux
  /// positif chez Jay. Sur une Vibe déjà épuisée (`vues 2 → 2`,
  /// `phase=exhausted`), l'écran refuse d'ouvrir : `open_card_media` n'est
  /// jamais appelée et le compteur ne bouge pas. Le verdict annonçait
  /// « ❌ DÉCOMPTE ANORMAL : 0 vue(s) » — alors que **ce zéro est précisément
  /// la preuve que la limite tient**. Un instrument qui note en rouge le
  /// comportement voulu fait chercher un bug là où il n'y en a pas.
  bool? get countingOk {
    if (limitsApply != true || consumed == null) return null;
    return consumed == (refusedAsExhausted ? 0 : 1);
  }

  static CardRulesTrace start(String cardId, String cardType) {
    final trace = CardRulesTrace._(cardId, cardType);
    if (!enabled) return trace;
    _records.insert(0, trace);
    if (_records.length > _maxRecords) _records.removeLast();
    return trace;
  }

  static List<CardRulesTrace> get records => List.unmodifiable(_records);

  static void clear() => _records.clear();

  void log(String label, {String? detail}) {
    if (!enabled) return;
    events.add(CardRuleEvent(label, detail: detail));
  }

  void faceSpent(bool front, int ms) {
    if (!enabled) return;
    final key = front ? 'recto' : 'verso';
    faceMs[key] = (faceMs[key] ?? 0) + ms;
  }

  /// Mise en forme pour le presse-papier — reprise telle quelle par le paquet
  /// de diagnostic.
  String describe() {
    final buffer = StringBuffer()
      ..writeln('[$cardType] $cardId')
      ..writeln(
        '  serveur   : max_views=${maxViews ?? '∞'} · '
        'durée/face=${viewDurationSeconds ?? '?'} s · '
        'saveable=${saveable ?? '?'} · scrubbable=${scrubbable ?? '?'} · '
        'chiffrée=${encrypted ?? '?'}',
      )
      ..writeln(
        '  livraison : vues ${viewCountBefore ?? '?'} → '
        '${viewCountAfter ?? '?'}'
        '${consumed == null ? '' : ' (consommé $consumed)'} · '
        'détruite=${destroyed ?? '?'} · replay=${replayGranted ?? '?'}',
      )
      ..writeln(
        '  écran     : limites=${limitsApply ?? '?'} · '
        'phase=${phase ?? '?'} · restant avant=${remainingBefore ?? '∞'}',
      );

    if (faceMs.isNotEmpty) {
      final spent = faceMs.entries
          .map((e) => '${e.key} ${(e.value / 1000).toStringAsFixed(1)} s')
          .join(' · ');
      buffer.writeln('  observé   : $spent');
    }

    final verdict = countingOk;
    if (verdict != null) {
      final expected = refusedAsExhausted ? 0 : 1;
      buffer.writeln(
        verdict
            ? refusedAsExhausted
                  ? '  ✅ budget épuisé : ouverture refusée, 0 vue consommée'
                  : '  ✅ décompte conforme (1 vue par ouverture)'
            : '  ❌ DÉCOMPTE ANORMAL : $consumed vue(s) pour une ouverture '
                  '(attendu $expected)',
      );
    }

    for (final event in events) {
      buffer.writeln(
        '    ${event.at.toIso8601String().substring(11, 23)} ${event.label}'
        '${event.detail == null ? '' : ' — ${event.detail}'}',
      );
    }
    return buffer.toString();
  }
}
