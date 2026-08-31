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
    required this.authorId,
    required this.revealAt,
    required this.saveableByOthers,
    required this.ephemeral,
    required this.placeholderPath,
    required this.sealedPath,
    required this.createdAt,
    required this.type,
    required this.frontIsVideo,
    required this.backIsVideo,
    this.placeholderBackPath,
    this.sealedBackPath,
  });

  final String id;
  final String conversationId;
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

  /// Type, pour l'identité visuelle seulement. Une vibe de bibliothèque
  /// **n'a ni limite de vues ni limite de durée** (décision de Jay) : les
  /// mécaniques de la Card envoyée ne s'y appliquent pas.
  final CardType type;

  final bool frontIsVideo;
  final bool backIsVideo;

  bool get hasBack => placeholderBackPath != null;

  /// Le contenu est-il révélé **à l'instant [now]** ? C'est une simple
  /// comparaison d'horloge, et c'est aussi la règle appliquée côté serveur —
  /// rien ne « bascule » à 18h30.
  ///
  /// ## 🔴 Pourquoi l'instant est un PARAMÈTRE — corrigé le 2026-08-31
  ///
  /// C'était `bool get revealed => DateTime.now().isAfter(revealAt)`, et trois
  /// `build()` le lisaient. Un `build` ne se rejoue que si l'une de ses sources
  /// change — et l'heure n'en était pas une.
  ///
  /// ⚠️ **Conséquence : le reveal ne se produisait pas à l'écran.** Quelqu'un
  /// qui attend 18h30 devant sa bibliothèque voyait les vibes rester masquées,
  /// jusqu'à ce qu'un événement sans rapport reconstruise le widget. C'est le
  /// défaut décrit dans `core/clock.dart` — mais posé sur le seul moment de
  /// l'app que les gens attendent vraiment.
  ///
  /// La règle du projet : on s'abonne au temps (`expiryClockProvider`), ou on
  /// assume l'instantané **en l'écrivant**. Ici on s'abonne, et l'instant
  /// descend d'en haut.
  bool revealedAt(DateTime now) => now.isAfter(revealAt);

  /// L'instantané, **réservé aux callbacks** — un geste se juge au moment où il
  /// est fait, et il n'y a alors rien à réafficher.
  ///
  /// ⚠️ **Jamais dans un `build`.** Voir [revealedAt].
  bool get revealedMaintenant => revealedAt(DateTime.now());

  /// Le serveur accepte-t-il déjà de livrer le média scellé **à [now]** ? Il
  /// ouvre 5 minutes avant, pour que l'app ait les octets en main à l'heure
  /// pile et que le reveal soit instantané. Les octets restent illisibles sans
  /// la clé.
  bool prefetchableAt(DateTime now) =>
      now.isAfter(revealAt.subtract(const Duration(minutes: 5)));

  /// L'instantané, pour le préchargement — qui est déclenché par un geste, pas
  /// par un affichage.
  bool get prefetchableMaintenant => prefetchableAt(DateTime.now());

  /// Jour de l'album auquel cette vibe appartient (les albums sont datés,
  /// consigne Jay). La journée de collecte allant de 18h30 à 18h30, c'est la
  /// date locale du reveal qui identifie l'album, pas celle de la prise.
  DateTime get albumDay {
    final local = revealAt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  factory LibraryVibe.fromJson(Map<String, dynamic> json) {
    return LibraryVibe(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      authorId: json['author_id'] as String,
      revealAt: DateTime.parse(json['reveal_at'] as String),
      saveableByOthers: json['saveable_by_others'] as bool? ?? false,
      ephemeral: json['ephemeral'] as bool? ?? false,
      placeholderPath: json['placeholder_path'] as String,
      sealedPath: json['sealed_path'] as String,
      placeholderBackPath: json['placeholder_back_path'] as String?,
      sealedBackPath: json['sealed_back_path'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      type: CardType.fromDb(json['card_type'] as String? ?? 'standard'),
      frontIsVideo: json['front_is_video'] as bool? ?? false,
      backIsVideo: json['back_is_video'] as bool? ?? false,
    );
  }

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
      other is LibraryVibe &&
      other.id == id &&
      other.conversationId == conversationId &&
      other.authorId == authorId &&
      other.revealAt == revealAt &&
      other.saveableByOthers == saveableByOthers &&
      other.ephemeral == ephemeral &&
      other.placeholderPath == placeholderPath &&
      other.sealedPath == sealedPath &&
      other.placeholderBackPath == placeholderBackPath &&
      other.sealedBackPath == sealedBackPath &&
      other.createdAt == createdAt &&
      other.type == type &&
      other.frontIsVideo == frontIsVideo &&
      other.backIsVideo == backIsVideo;

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    authorId,
    revealAt,
    saveableByOthers,
    ephemeral,
    placeholderPath,
    sealedPath,
    placeholderBackPath,
    sealedBackPath,
    createdAt,
    type,
    frontIsVideo,
    backIsVideo,
  );
}
