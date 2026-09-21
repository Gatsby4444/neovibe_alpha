import 'card.dart';

/// **Le seul format de la bibliothèque : la Vibe** (`library_items.kind =
/// 'card'`). Les albums (`album`) et les Flows (`flow`) ont existé du
/// 2026-09-15 au 2026-09-21 et sont sortis du MVP (Jay : *« un éditeur pour
/// un format »*) ; la base garde son énumération à trois valeurs, l'app
/// n'écrit et ne lit que celle-ci — `LibraryRepository` et `feed_items`
/// filtrent sur elle, positivement.
const kLibraryKindVibe = 'card';

/// Un média d'une publication, à sa place : place 0 = recto, place 1 =
/// verso. Les deux sont scellés avec **la même clé** (`content_media_keys`,
/// une ligne par contenu).
class LibraryMedia {
  const LibraryMedia({
    required this.slot,
    required this.path,
    this.isVideo = false,
    this.durationMs,
    this.posterPath,
    this.width,
    this.height,
  });

  final int slot;
  final String path;
  final bool isVideo;

  /// Vidéo : sa durée en millisecondes. Nulle pour une face de Vibe (la
  /// capture ne la mesure pas).
  final int? durationMs;

  /// Une image de couverture, scellée avec la même clé. Nulle pour une face
  /// de Vibe (sa vignette reste une icône — `RAPPELS.md` #4) ; la colonne
  /// reste en base.
  final String? posterPath;

  final int? width;
  final int? height;

  factory LibraryMedia.fromJson(Map<String, dynamic> json) => LibraryMedia(
    slot: json['slot'] as int,
    path: json['path'] as String,
    isVideo: json['is_video'] as bool? ?? false,
    durationMs: json['duration_ms'] as int?,
    posterPath: json['poster_path'] as String?,
    width: json['width'] as int?,
    height: json['height'] as int?,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryMedia &&
      other.slot == slot &&
      other.path == path &&
      other.isVideo == isVideo &&
      other.durationMs == durationMs &&
      other.posterPath == posterPath &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode =>
      Object.hash(slot, path, isVideo, durationMs, posterPath, width, height);
}

/// Une **publication** de bibliothèque de profil — objet autonome depuis la
/// refonte « 1 contenu = 1 format » (2026-08-11).
///
/// Avant, `library_items` mélangeait deux natures : les publications issues de
/// la caméra n'étaient qu'une ligne pointant vers une Card (donc soumises aux
/// règles de livraison, dans le bucket `cards`), tandis que les photos
/// importées vivaient en clair dans le bucket `library`. Deux régimes dans une
/// seule table.
///
/// Désormais une publication porte ses propres médias dans le bucket
/// `library`, avec une seule règle d'accès. Son [id] **est** le Content ID.
///
/// **Depuis le 2026-09-15, les médias sont une LISTE** (`library_media`) :
/// une Vibe y a ses faces aux places 0 et 1. [frontPath], [backPath] et
/// compagnie sont des lectures dérivées de ces deux places.
///
/// **Permanente** : aucune date d'expiration (décision de Jay du 2026-08-11,
/// « c'est ce qui a toujours été décidé »).
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.ownerId,
    required this.media,
    required this.createdAt,
    this.cardType = CardType.standard,
    this.caption,
    this.isPublic = false,
    this.shareable = false,
    this.saveable = false,
    this.encrypted = true,
  }) : assert(media.length > 0, 'Une publication a au moins un média');

  /// Content ID : identifiant unique et persistant, commun à `contents`,
  /// `content_grants` et `content_views`.
  final String id;
  final String ownerId;

  /// Le type de Vibe (standard, oneshot, bereal).
  final CardType cardType;

  /// Les médias, **triés par place**. Jamais vide.
  final List<LibraryMedia> media;

  /// Une Vibe n'a pas de description (Jay, 2026-09-17) : nulle aujourd'hui,
  /// la colonne reste en base.
  final String? caption;

  /// Publication publique : visible par toute personne accédant au profil
  /// par un moyen légitime (un rang au-dessus de « connexions »).
  final bool isPublic;

  /// L'auteur autorise la propagation de cercle en cercle. Porté par
  /// `contents`, pas par `library_items` : la partageabilité appartient au
  /// CONTENU, quel que soit son format. Il arrive donc par la jointure.
  final bool shareable;

  /// L'auteur autorise la copie locale dans les Enregistrements. Porté par
  /// `contents`, comme [shareable] : la sauvegardabilité appartient au CONTENU,
  /// quel que soit son format.
  final bool saveable;

  /// Médias chiffrés au dépôt : la clé ne s'obtient que par
  /// `open_content_media`, ou en lot par `library_media_keys`.
  final bool encrypted;

  final DateTime createdAt;

  // ── Lectures dérivées : les faces (places 0 et 1) ──────────────────────

  LibraryMedia get front => media.first;
  LibraryMedia? get back => media.length > 1 ? media[1] : null;

  String get frontPath => front.path;
  String? get backPath => back?.path;
  bool get frontIsVideo => front.isVideo;
  bool get backIsVideo => back?.isVideo ?? false;

  /// Null = Vibe à face unique (le verso a été passé à la prise).
  bool get hasBack => back != null;

  factory LibraryItem.fromJson(Map<String, dynamic> json) {
    final rows =
        (json['library_media'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(LibraryMedia.fromJson)
            .toList()
          ..sort((a, b) => a.slot.compareTo(b.slot));
    return LibraryItem(
      id: json['id'] as String,
      ownerId: json['owner_id'] as String,
      cardType: CardType.fromDb(json['card_type'] as String),
      media: rows,
      caption: json['caption'] as String?,
      isPublic: json['is_public'] as bool? ?? false,
      shareable:
          (json['contents'] as Map<String, dynamic>?)?['shareable'] as bool? ??
          false,
      saveable:
          (json['contents'] as Map<String, dynamic>?)?['saveable'] as bool? ??
          false,
      encrypted: json['encrypted'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  /// La jointure à demander à PostgREST pour obtenir tout ce que [fromJson]
  /// lit — un seul endroit à tenir quand une colonne change.
  static const select = '*, contents(shareable, saveable), library_media(*)';

  // 🔴 **ÉGALITÉ DE VALEUR — posée le 2026-08-31, six jours après les autres.**
  //
  // Le balayage du 2026-08-25 (checkup `RAPPELS.md` #52) a donné son `==` à
  // sept modèles — Card, Connection, ConnectionRequest, Message, Profile,
  // Story, Wave — et **a manqué celui-ci**. Sa propre règle disait pourtant :
  // *« vérifier par inventaire, pas par le diff »*. L'inventaire n'avait pas
  // été fait sur le dossier des modèles.
  //
  // ⚠️ **Sans `==`, la comparaison retombe sur l'IDENTITÉ, en silence.** Ce
  // type vit dans une liste rendue par un provider : chaque rechargement
  // fabrique de nouveaux objets, donc une liste jamais égale à la précédente,
  // donc **tous les écrans qui l'observent se reconstruisent** — même quand
  // l'utilisateur verrait exactement la même chose. Rien ne s'affiche de faux ;
  // c'est un coût qui ne se voit qu'en comptant.
  @override
  bool operator ==(Object other) =>
      other is LibraryItem &&
      other.id == id &&
      other.ownerId == ownerId &&
      other.cardType == cardType &&
      _sameMedia(other.media, media) &&
      other.caption == caption &&
      other.isPublic == isPublic &&
      other.shareable == shareable &&
      other.saveable == saveable &&
      other.encrypted == encrypted &&
      other.createdAt == createdAt;

  static bool _sameMedia(List<LibraryMedia> a, List<LibraryMedia> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    ownerId,
    cardType,
    Object.hashAll(media),
    caption,
    isPublic,
    shareable,
    saveable,
    encrypted,
    createdAt,
  );
}
