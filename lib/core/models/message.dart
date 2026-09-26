import 'package:flutter/foundation.dart';
import 'card.dart';
import 'profile.dart';

enum MessageKind {
  text,
  image,
  video,
  card,

  /// Annonce système : « X a ajouté une vibe » à la bibliothèque éphémère de
  /// la conversation (2026-08-10). Rendue comme une ligne discrète et centrée,
  /// pas comme une bulle.
  libraryAdd,

  /// **Repartage** d'une story ou d'une publication (2026-08-11). Ce n'est
  /// pas une copie : le message porte un simple chemin vers la source, et
  /// l'ouvrir ouvre la source. Si celle-ci disparaît, le message reste et le
  /// dit — au lieu de s'évaporer en silence.
  contentShare,

  /// **Message vocal** (2026-09-13) : un média de message scellé, dans le
  /// bucket `media`, dont la clé ne sort que par `open_voice_message`. Vit
  /// 24 h avec son message. DM et groupes seulement — jamais le canal de
  /// proximité (règle serveur), ni l'événement (choix par défaut).
  voice,

  /// **Demande de position d'un ami** (2026-09-26) : le corps porte
  /// l'identifiant de la demande ; son état vient du serveur. Le serveur
  /// refuse un tel message s'il ne correspond pas à une vraie demande.
  locationRequest;

  /// Le nom Dart et la valeur en base diffèrent (`libraryAdd` / `library_add`),
  /// d'où la table explicite plutôt que `byName`.
  ///
  /// ⚠️ Et surtout : `byName` **lève** sur une valeur inconnue. Un client plus
  /// ancien que la base aurait vu la conversation entière échouer au premier
  /// message d'un type qu'il ne connaît pas. Le repli sur [text] garantit qu'un
  /// APK déjà installé continue d'afficher le fil.
  static MessageKind fromDb(String value) => switch (value) {
    'text' => MessageKind.text,
    'image' => MessageKind.image,
    'video' => MessageKind.video,
    'card' => MessageKind.card,
    'library_add' => MessageKind.libraryAdd,
    'content_share' => MessageKind.contentShare,
    'voice' => MessageKind.voice,
    'location_request' => MessageKind.locationRequest,
    _ => MessageKind.text,
  };

  String get dbValue => switch (this) {
    MessageKind.text => 'text',
    MessageKind.image => 'image',
    MessageKind.video => 'video',
    MessageKind.card => 'card',
    MessageKind.libraryAdd => 'library_add',
    MessageKind.contentShare => 'content_share',
    MessageKind.voice => 'voice',
    MessageKind.locationRequest => 'location_request',
  };
}

class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.kind,
    this.body,
    this.mediaPath,
    this.cardId,
    this.contentId,
    this.duration,
    required this.createdAt,
    required this.expiresAt,
    this.sender,
    this.card,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final MessageKind kind;
  final String? body;
  final String? mediaPath;
  final String? cardId;

  /// Content ID visé par un [MessageKind.contentShare]. **Null quand la source
  /// a disparu** : la contrainte est en `on delete set null`, donc le message
  /// survit à ce qu'il désignait et peut l'annoncer.
  final String? contentId;

  /// Durée d'un [MessageKind.voice], portée par le message lui-même : l'écran
  /// l'affiche avant d'avoir téléchargé un octet. Nulle pour les autres genres.
  final Duration? duration;

  final DateTime createdAt;
  final DateTime expiresAt;
  final Profile? sender;
  final CardModel? card;

  bool get isExpired => expiresAt.isBefore(DateTime.now());

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    senderId: json['sender_id'] as String,
    kind: MessageKind.fromDb(json['kind'] as String? ?? 'text'),
    body: json['body'] as String?,
    mediaPath: json['media_path'] as String?,
    cardId: json['card_id'] as String?,
    contentId: json['content_id'] as String?,
    duration: json['duration_ms'] == null
        ? null
        : Duration(milliseconds: (json['duration_ms'] as num).toInt()),
    createdAt: DateTime.parse(json['created_at'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    sender: json['sender'] == null
        ? null
        : Profile.fromJson(json['sender'] as Map<String, dynamic>),
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
  );

  // ⚠️ **Égalité de VALEUR, posée le 2026-08-25 (checkup `RAPPELS.md` #52).**
  //
  // ⚠️ `isExpired` n'en fait PAS partie, et c'est délibéré : il se calcule sur
  // `DateTime.now()`. L'inclure ferait dépendre l'égalité de l'instant où on la
  // teste — deux messages identiques seraient tantôt égaux, tantôt non. La
  // péremption est une décision d'AFFICHAGE, elle appartient au consommateur
  // (voir `core/clock.dart`).
  @override
  bool operator ==(Object other) =>
      other is Message &&
      other.id == id &&
      other.conversationId == conversationId &&
      other.senderId == senderId &&
      other.kind == kind &&
      other.body == body &&
      other.mediaPath == mediaPath &&
      other.cardId == cardId &&
      other.contentId == contentId &&
      other.duration == duration &&
      other.createdAt == createdAt &&
      other.expiresAt == expiresAt &&
      other.sender == sender &&
      other.card == card;

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    senderId,
    kind,
    body,
    mediaPath,
    cardId,
    contentId,
    duration,
    createdAt,
    expiresAt,
    sender,
    card,
  );
}

enum ConversationType {
  direct,
  group,
  proximity,

  /// Le **groupe d'événement** (2026-09-12) : éphémère, construit pour un
  /// seul événement, tenu hors du Cercle. Il vit 5 jours après la fermeture
  /// de l'événement, puis le serveur le purge avec lui. Jamais un groupe
  /// existant — consigne de Jay : *« on distingue bien les deux »*.
  event;

  static ConversationType fromDb(String value) =>
      ConversationType.values.byName(value);

  /// Plusieurs personnes autour d'un titre : un groupe, ou un groupe
  /// d'événement. C'est ce que les écrans veulent savoir quand ils demandent
  /// « est-ce un groupe ? » — pas le type exact.
  bool get isCollective =>
      this == ConversationType.group || this == ConversationType.event;
}

class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    this.title,
    required this.createdAt,
    this.createdBy,
    this.members = const [],
    this.lastActivityAt,
    this.lastMessage,
  });

  final String id;
  final ConversationType type;
  final String? title;
  final DateTime createdAt;

  /// Qui a créé ce groupe. **Nul** pour une conversation directe ou de
  /// proximité, et pour un groupe dont le créateur a supprimé son compte
  /// (`on delete set null`).
  ///
  /// ## 🔴 Pourquoi ce champ est arrivé le 2026-08-31
  ///
  /// La règle serveur de retrait d'un membre est passée de « n'importe quel
  /// membre » à « soi-même, ou le créateur » (décision de Jay). L'écran des
  /// réglages de groupe, lui, offrait le bouton « Retirer » à **tout le
  /// monde**.
  ///
  /// ⚠️ **Et l'échec aurait été SILENCIEUX** : un `delete` refusé par la
  /// sécurité au niveau des lignes ne lève pas, il supprime zéro ligne et
  /// répond « ok ». L'écran se serait rechargé avec le membre toujours là,
  /// sans un mot. C'est le « mur sans issue » de `CLAUDE.md` — un bouton dont
  /// le seul effet possible est de ne rien faire.
  ///
  /// La colonne existait déjà en base et était simplement ignorée à la
  /// lecture.
  final String? createdBy;
  final List<Profile> members;
  final Message? lastMessage;

  /// Le dernier message de qui que ce soit — entretenu par le serveur
  /// (`conversations.last_activity_at`, trigger sur `messages`) et donc
  /// **connu même après la purge des messages à 24 h**. C'est la date qui
  /// trie « tout le monde » dans l'écran de partage (2026-09-14). Nulle pour
  /// une conversation où personne n'a jamais écrit.
  final DateTime? lastActivityAt;

  /// Nom affiché : titre du groupe, ou nom de l'autre membre en 1-à-1
  /// (tag name en priorité — consigne Jay —, sinon username).
  String displayName(String me) {
    if (type == ConversationType.event) return title ?? 'Événement';
    if (type == ConversationType.group) return title ?? 'Groupe';
    final other = members.where((m) => m.id != me).firstOrNull;
    return other?.chatName ?? 'Conversation';
  }

  Profile? otherMember(String me) =>
      members.where((m) => m.id != me).firstOrNull;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    type: ConversationType.fromDb(json['conversation_type'] as String),
    title: json['title'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    createdBy: json['created_by'] as String?,
    members: (json['members'] as List<dynamic>? ?? [])
        .map(
          (m) => Profile.fromJson(
            (m as Map<String, dynamic>)['profiles'] as Map<String, dynamic>,
          ),
        )
        .toList(),
    lastActivityAt: json['last_activity_at'] == null
        ? null
        : DateTime.parse(json['last_activity_at'] as String),
  );

  Conversation copyWith({Message? lastMessage, List<Profile>? members}) =>
      Conversation(
        id: id,
        type: type,
        title: title,
        createdAt: createdAt,
        createdBy: createdBy,
        members: members ?? this.members,
        lastMessage: lastMessage ?? this.lastMessage,
        lastActivityAt: lastActivityAt,
      );

  // ⚠️ **Égalité de VALEUR, posée le 2026-08-25 (checkup `RAPPELS.md` #52).**
  //
  // Ce type contient une LISTE : sans `listEquals`, comparer ce champ
  // reviendrait à comparer deux adresses mémoire, et l'égalité de l'objet
  // entier serait fausse dès le premier rechargement.
  @override
  bool operator ==(Object other) =>
      other is Conversation &&
      other.id == id &&
      other.type == type &&
      other.title == title &&
      other.createdBy == createdBy &&
      other.createdAt == createdAt &&
      other.lastMessage == lastMessage &&
      other.lastActivityAt == lastActivityAt &&
      listEquals(other.members, members);

  @override
  int get hashCode => Object.hash(
    id,
    type,
    title,
    createdAt,
    lastMessage,
    lastActivityAt,
    Object.hashAll(members),
  );
}
