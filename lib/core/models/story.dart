import 'card.dart';
import 'profile.dart';

/// Une story est un **objet autonome** depuis la refonte « 1 contenu = 1
/// format » (2026-08-11).
///
/// Avant, une story n'était qu'une ligne pointant vers une Card : la même Card
/// pouvait être envoyée en DM, publiée en bibliothèque ET mise en story, avec
/// trois régimes d'accès contradictoires sur un seul fichier. C'est ce qui
/// faisait qu'une story annulait en silence la limite de vues promise à un
/// destinataire.
///
/// Désormais une story porte ses propres fichiers (bucket `stories`), son
/// propre type, sa propre durée de vie et **aucune limite de vues** — 24 h,
/// consultable autant qu'on veut. Son [id] **est** le Content ID : la même
/// valeur identifie la ligne `contents`, le graphe de propagation et les vues.
class Story {
  const Story({
    required this.id,
    required this.ownerId,
    required this.cardType,
    required this.frontPath,
    required this.createdAt,
    required this.expiresAt,
    this.backPath,
    this.frontIsVideo = false,
    this.backIsVideo = false,
    this.shareable = false,
    this.saveable = false,
    this.encrypted = true,
    this.owner,
  });

  /// Content ID : identifiant unique et persistant du contenu, commun à
  /// `contents`, `content_grants` et `content_views`.
  final String id;
  final String ownerId;

  /// Type visuel repris de la capture (`standard`, `oneshot`…). Le chantier
  /// « stories en deck » (dérivé sans recto/verso) reste bloqué sur 3 questions
  /// posées à Jay le 2026-08-02 : on garde le format actuel d'ici là.
  final CardType cardType;

  final String frontPath;

  /// Null = story à face unique.
  final String? backPath;

  final bool frontIsVideo;
  final bool backIsVideo;

  /// L'auteur autorise la propagation de cercle en cercle (décision de Jay du
  /// 2026-08-11). **Faux par défaut** : le partage hors cercle est un acte
  /// délibéré, repris à chaque publication — il n'existe pas de réglage global
  /// « compte public ».
  ///
  /// Porté par `contents`, pas par `stories` : la partageabilité appartient au
  /// CONTENU, quel que soit son format. Il arrive donc par la jointure.
  final bool shareable;

  /// L'auteur autorise la copie locale dans les Enregistrements. Porté par
  /// `contents`, comme [shareable] : la sauvegardabilité appartient au CONTENU,
  /// quel que soit son format.
  final bool saveable;

  /// Faces chiffrées au dépôt : la clé ne s'obtient que par
  /// `open_content_media`, la porte unique du socle de contenu.
  final bool encrypted;

  final DateTime createdAt;
  final DateTime expiresAt;

  /// Auteur, joint pour l'affichage (pastille + pseudo).
  final Profile? owner;

  bool get hasBack => backPath != null;

  factory Story.fromJson(Map<String, dynamic> json) => Story(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    cardType: CardType.fromDb(json['card_type'] as String),
    frontPath: json['front_path'] as String,
    backPath: json['back_path'] as String?,
    frontIsVideo: json['front_is_video'] as bool? ?? false,
    backIsVideo: json['back_is_video'] as bool? ?? false,
    shareable:
        (json['contents'] as Map<String, dynamic>?)?['shareable'] as bool? ??
        false,
    saveable:
        (json['contents'] as Map<String, dynamic>?)?['saveable'] as bool? ??
        false,
    encrypted: json['encrypted'] as bool? ?? true,
    createdAt: DateTime.parse(json['created_at'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    owner: json['profiles'] == null
        ? null
        : Profile.fromJson(json['profiles'] as Map<String, dynamic>),
  );
}

/// Stories d'un même auteur, regroupées pour le bandeau horizontal.
class StoryRing {
  const StoryRing({required this.owner, required this.stories});

  final Profile owner;
  final List<Story> stories;

  DateTime get latestAt => stories.first.createdAt;
}

/// Un spectateur d'une de MES stories, tel que le serveur accepte de le
/// nommer.
///
/// `content_viewers` ne renvoie que les spectateurs que l'auteur peut situer
/// dans son cercle ; les autres n'existent que dans le **compte total**
/// (`content_viewer_count`). Le nominatif complet est enregistré côté serveur et
/// réservé à la future option premium (décision de Jay 2026-08-11).
class StoryViewer {
  const StoryViewer({
    required this.viewerId,
    required this.firstViewedAt,
    this.displayName,
    this.tagName,
    this.avatarUrl,
  });

  final String viewerId;
  final DateTime firstViewedAt;
  final String? displayName;
  final String? tagName;
  final String? avatarUrl;

  factory StoryViewer.fromJson(Map<String, dynamic> json) => StoryViewer(
    viewerId: json['viewer_id'] as String,
    firstViewedAt: DateTime.parse(json['first_viewed_at'] as String),
    displayName: json['display_name'] as String?,
    tagName: json['tag_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
  );
}
