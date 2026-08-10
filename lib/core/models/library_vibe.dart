import 'card.dart';

/// Une vibe déposée dans la **bibliothèque éphémère** d'une conversation.
///
/// Spécification : `docs/bibliotheques-ephemeres.md`. Le principe tient en une
/// phrase : on ajoute une vibe à une bibliothèque partagée au lieu de
/// l'envoyer, et **personne** ne la voit — pas même son auteur — jusqu'au
/// reveal de 18h30.
///
/// Le masquage ne repose pas sur cet objet ni sur l'app : avant [revealAt], le
/// serveur refuse la clé de déchiffrement (`get_library_vibe_key`). Ce qui est
/// téléchargé d'ici là est soit le placeholder — l'image réduite à ~20 px, donc
/// l'information est détruite, pas brouillée —, soit un bloc illisible.
class LibraryVibe {
  const LibraryVibe({
    required this.id,
    required this.conversationId,
    required this.cardId,
    required this.authorId,
    required this.revealAt,
    required this.saveableByOthers,
    required this.ephemeral,
    required this.placeholderPath,
    required this.sealedPath,
    required this.createdAt,
    this.placeholderBackPath,
    this.sealedBackPath,
    this.card,
  });

  final String id;
  final String conversationId;
  final String cardId;
  final String authorId;

  /// Instant du reveal, identique pour tous les membres de la conversation
  /// (le fuseau est fixé à sa création — consigne Jay : un seul instant réel,
  /// sans quoi le moment partagé disparaît).
  final DateTime revealAt;

  /// Posé par l'auteur à la prise. Gouverne **les autres** : l'auteur peut
  /// toujours sauvegarder sa propre vibe une fois révélée.
  final bool saveableByOthers;

  /// Disparaît 24 h après le reveal. Faux par défaut — le but est une
  /// bibliothèque souvenir.
  final bool ephemeral;

  final String placeholderPath;
  final String sealedPath;

  /// Verso — null pour une vibe à face unique. Masqué et scellé comme le recto,
  /// pour qu'on puisse retourner la vibe **même floutée** (demande de Jay,
  /// 2026-08-10).
  final String? placeholderBackPath;
  final String? sealedBackPath;

  final DateTime createdAt;

  bool get hasBack => placeholderBackPath != null;

  /// La vibe elle-même, jointe quand on en a besoin (type, faces vidéo…).
  final CardModel? card;

  /// Le contenu est-il révélé ? C'est une simple comparaison d'horloge, et
  /// c'est aussi la règle appliquée côté serveur — rien ne « bascule » à 18h30.
  bool get revealed => DateTime.now().isAfter(revealAt);

  /// Le serveur accepte-t-il déjà de livrer le média scellé ? Il ouvre 5
  /// minutes avant, pour que l'app ait les octets en main à l'heure pile et que
  /// le reveal soit instantané. Les octets restent illisibles sans la clé.
  bool get prefetchable =>
      DateTime.now().isAfter(revealAt.subtract(const Duration(minutes: 5)));

  /// Jour de l'album auquel cette vibe appartient (les albums sont datés,
  /// consigne Jay). La journée de collecte allant de 18h30 à 18h30, c'est la
  /// date locale du reveal qui identifie l'album, pas celle de la prise.
  DateTime get albumDay {
    final local = revealAt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  factory LibraryVibe.fromJson(Map<String, dynamic> json) {
    final rawCard = json['cards'];
    return LibraryVibe(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      cardId: json['card_id'] as String,
      authorId: json['author_id'] as String,
      revealAt: DateTime.parse(json['reveal_at'] as String),
      saveableByOthers: json['saveable_by_others'] as bool? ?? false,
      ephemeral: json['ephemeral'] as bool? ?? false,
      placeholderPath: json['placeholder_path'] as String,
      sealedPath: json['sealed_path'] as String,
      placeholderBackPath: json['placeholder_back_path'] as String?,
      sealedBackPath: json['sealed_back_path'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      card: rawCard is Map<String, dynamic>
          ? CardModel.fromJson(rawCard)
          : null,
    );
  }
}
