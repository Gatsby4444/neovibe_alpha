import 'card.dart';

/// Le format d'une publication de bibliothèque (2026-09-15).
///
/// Les deux obéissent aux **mêmes règles** — même audience, permanentes,
/// aucune limite de vues, mêmes droits portés par `contents`. Seul le format
/// change : une Card se **retourne**, un album se **feuillette**. C'est
/// pourquoi ils partagent l'en-tête `library_items` (règle 2 de `CLAUDE.md` :
/// deux objets aux règles différentes ne partagent pas la table — ici les
/// règles sont les mêmes). Détail : `docs/plan-publications.md` §2.
enum LibraryKind {
  /// Une ou deux faces (places 0 et 1), au format Card.
  card,

  /// De 1 à 11 médias, photos et vidéos mêlées, à un ratio commun. Le mot
  /// n'apparaît pas dans l'interface : on dit « publication ».
  album;

  static LibraryKind fromDb(String value) =>
      value == 'album' ? LibraryKind.album : LibraryKind.card;

  String get dbValue => name;
}

/// Le ratio d'un album, commun à tous ses médias.
///
/// **Un seul est proposé : [tall], 3:4** — « vertical comme sur Instagram »,
/// tranché par Jay le 2026-09-15 après le test de la v0.9.185. Les trois
/// autres restent lisibles pour les albums publiés avant (le visionneur
/// affiche chaque album à SON ratio), mais l'éditeur ne les offre plus.
enum AlbumAspect {
  tall(3, 4, '3:4'),
  square(1, 1, '1:1'),
  portrait(4, 5, '4:5'),
  landscape(191, 100, '1.91:1');

  const AlbumAspect(this.w, this.h, this.label);

  /// Les deux entiers stockés en base (`aspect_w`, `aspect_h`).
  final int w;
  final int h;
  final String label;

  double get ratio => w / h;

  static AlbumAspect? fromDb(int? w, int? h) {
    for (final a in values) {
      if (a.w == w && a.h == h) return a;
    }
    return null;
  }
}

/// Un média d'une publication, à sa place.
///
/// Une Card : place 0 = recto, place 1 = verso. Un album : de 0 à 10.
/// Tous les médias d'une publication sont scellés avec **la même clé**
/// (`content_media_keys`, une ligne par contenu).
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

  /// Vidéo : sa durée en millisecondes (≤ 60 000 pour un album).
  final int? durationMs;

  /// Vidéo d'album : son image de couverture, scellée avec la même clé.
  /// Nul pour les vidéos de Card (leur vignette reste une icône — `RAPPELS.md` #4).
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
/// **Depuis le 2026-09-15, les médias sont une LISTE** (`library_media`), pour
/// les deux formats : une Card y a ses faces aux places 0 et 1, un album ses
/// 1 à 11 médias. [frontPath], [backPath] et compagnie sont des lectures
/// dérivées des places 0 et 1 — les écrans Card n'ont rien eu à réapprendre.
///
/// **Permanente** : aucune date d'expiration (décision de Jay du 2026-08-11,
/// « c'est ce qui a toujours été décidé »).
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.ownerId,
    required this.media,
    required this.createdAt,
    this.kind = LibraryKind.card,
    this.cardType = CardType.standard,
    this.aspect,
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

  final LibraryKind kind;

  /// Le type de Card. Pour un album, la base garde le défaut `standard` : il
  /// ne sert qu'à l'habillage commun de la grille (liseré), jamais à une règle.
  final CardType cardType;

  /// Le ratio d'un album ; nul pour une Card.
  final AlbumAspect? aspect;

  /// Les médias, **triés par place**. Jamais vide.
  final List<LibraryMedia> media;

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

  bool get isAlbum => kind == LibraryKind.album;

  // ── Lectures dérivées pour le format Card (places 0 et 1) ──────────────

  LibraryMedia get front => media.first;
  LibraryMedia? get back => media.length > 1 ? media[1] : null;

  String get frontPath => front.path;
  String? get backPath => back?.path;
  bool get frontIsVideo => front.isVideo;
  bool get backIsVideo => back?.isVideo ?? false;

  /// Null = publication à face unique (une photo importée, ou une Vibe dont le
  /// verso a été passé à la prise).
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
      kind: LibraryKind.fromDb(json['kind'] as String? ?? 'card'),
      cardType: CardType.fromDb(json['card_type'] as String),
      aspect: AlbumAspect.fromDb(
        json['aspect_w'] as int?,
        json['aspect_h'] as int?,
      ),
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
      other.kind == kind &&
      other.cardType == cardType &&
      other.aspect == aspect &&
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
    kind,
    cardType,
    aspect,
    Object.hashAll(media),
    caption,
    isPublic,
    shareable,
    saveable,
    encrypted,
    createdAt,
  );
}
