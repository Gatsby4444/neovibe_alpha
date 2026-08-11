import 'card.dart';

/// Une **publication** de bibliothèque de profil — objet autonome depuis la
/// refonte « 1 contenu = 1 format » (2026-08-11).
///
/// Avant, `library_items` mélangeait deux natures : les publications issues de
/// la caméra n'étaient qu'une ligne pointant vers une Card (donc soumises aux
/// règles de livraison, dans le bucket `cards`), tandis que les photos
/// importées vivaient en clair dans le bucket `library`. Deux régimes dans une
/// seule table.
///
/// Désormais une publication porte ses propres faces dans le bucket `library`,
/// avec une seule règle d'accès. Son [id] **est** le Content ID.
///
/// **Permanente** : aucune date d'expiration (décision de Jay du 2026-08-11,
/// « c'est ce qui a toujours été décidé »).
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.ownerId,
    required this.cardType,
    required this.frontPath,
    required this.createdAt,
    this.backPath,
    this.frontIsVideo = false,
    this.backIsVideo = false,
    this.caption,
    this.isPublic = false,
    this.shareable = false,
    this.encrypted = true,
  });

  /// Content ID : identifiant unique et persistant, commun à `contents`,
  /// `content_grants` et `content_views`.
  final String id;
  final String ownerId;

  final CardType cardType;
  final String frontPath;

  /// Null = publication à face unique (une photo importée, ou une Vibe dont le
  /// verso a été passé à la prise).
  final String? backPath;

  final bool frontIsVideo;
  final bool backIsVideo;
  final String? caption;

  /// Publication publique : visible par toute personne accédant au profil
  /// par un moyen légitime (un rang au-dessus de « connexions »).
  final bool isPublic;

  /// L'auteur autorise la propagation de cercle en cercle. Porté par
  /// `contents`, pas par `library_items` : la partageabilité appartient au
  /// CONTENU, quel que soit son format. Il arrive donc par la jointure.
  final bool shareable;

  /// Faces chiffrées au dépôt : la clé ne s'obtient que par
  /// `open_content_media`, ou en lot par `library_media_keys`.
  final bool encrypted;

  final DateTime createdAt;

  bool get hasBack => backPath != null;

  factory LibraryItem.fromJson(Map<String, dynamic> json) => LibraryItem(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    cardType: CardType.fromDb(json['card_type'] as String),
    frontPath: json['front_path'] as String,
    backPath: json['back_path'] as String?,
    frontIsVideo: json['front_is_video'] as bool? ?? false,
    backIsVideo: json['back_is_video'] as bool? ?? false,
    caption: json['caption'] as String?,
    isPublic: json['is_public'] as bool? ?? false,
    shareable:
        (json['contents'] as Map<String, dynamic>?)?['shareable'] as bool? ??
        false,
    encrypted: json['encrypted'] as bool? ?? true,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
