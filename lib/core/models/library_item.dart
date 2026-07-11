import 'card.dart';

class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.ownerId,
    required this.kind,
    this.cardId,
    this.mediaPath,
    this.caption,
    required this.createdAt,
    this.card,
  });

  final String id;
  final String ownerId;

  /// 'photo' | 'video' | 'card'
  final String kind;
  final String? cardId;
  final String? mediaPath;
  final String? caption;
  final DateTime createdAt;
  final CardModel? card;

  factory LibraryItem.fromJson(Map<String, dynamic> json) => LibraryItem(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    kind: json['kind'] as String,
    cardId: json['card_id'] as String?,
    mediaPath: json['media_path'] as String?,
    caption: json['caption'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
  );
}
