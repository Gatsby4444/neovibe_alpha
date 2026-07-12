import 'card.dart';
import 'profile.dart';

enum MessageKind {
  text,
  image,
  video,
  card;

  static MessageKind fromDb(String value) => MessageKind.values.byName(value);
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
    createdAt: DateTime.parse(json['created_at'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    sender: json['sender'] == null
        ? null
        : Profile.fromJson(json['sender'] as Map<String, dynamic>),
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
  );
}

enum ConversationType {
  direct,
  group,
  proximity;

  static ConversationType fromDb(String value) =>
      ConversationType.values.byName(value);
}

class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    this.title,
    required this.createdAt,
    this.members = const [],
    this.lastMessage,
  });

  final String id;
  final ConversationType type;
  final String? title;
  final DateTime createdAt;
  final List<Profile> members;
  final Message? lastMessage;

  /// Nom affiché : titre du groupe, ou nom de l'autre membre en 1-à-1
  /// (tag name en priorité — consigne Jay —, sinon username).
  String displayName(String me) {
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
    members: (json['members'] as List<dynamic>? ?? [])
        .map(
          (m) => Profile.fromJson(
            (m as Map<String, dynamic>)['profiles'] as Map<String, dynamic>,
          ),
        )
        .toList(),
  );

  Conversation copyWith({Message? lastMessage, List<Profile>? members}) =>
      Conversation(
        id: id,
        type: type,
        title: title,
        createdAt: createdAt,
        members: members ?? this.members,
        lastMessage: lastMessage ?? this.lastMessage,
      );
}
