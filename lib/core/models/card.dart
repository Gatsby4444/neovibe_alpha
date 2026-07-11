import 'package:flutter/material.dart';

/// Types de Cards — énumération extensible (spec 4.8.1).
enum CardType {
  standard,
  oneshot,
  oneOfOne,
  hot,
  bereal;

  static CardType fromDb(String value) => switch (value) {
    'standard' => CardType.standard,
    'oneshot' => CardType.oneshot,
    'one_of_one' => CardType.oneOfOne,
    'hot' => CardType.hot,
    'bereal' => CardType.bereal,
    _ => CardType.standard,
  };

  String get dbValue => switch (this) {
    CardType.standard => 'standard',
    CardType.oneshot => 'oneshot',
    CardType.oneOfOne => 'one_of_one',
    CardType.hot => 'hot',
    CardType.bereal => 'bereal',
  };

  /// Tag textuel visible sur la Card (spec 4.8.1).
  String get tag => switch (this) {
    CardType.standard => 'Card',
    CardType.oneshot => 'Oneshot',
    CardType.oneOfOne => '1/1',
    CardType.hot => 'Hot',
    CardType.bereal => 'BeReal',
  };

  /// Couleur signature du type — reconnaissable sans lire le tag.
  Color get color => switch (this) {
    CardType.standard => const Color(0xFF7C8CF8), // indigo neutre
    CardType.oneshot => const Color(0xFFE53E5B), // rouge urgence
    CardType.oneOfOne => const Color(0xFFD4AF37), // or exclusivité
    CardType.hot => const Color(0xFFFF7A1A), // orange énergie
    CardType.bereal => const Color(0xFF9E9E9E), // gris sobre
  };

  String get description => switch (this) {
    CardType.standard => 'Recto/verso classique, sans contrainte',
    CardType.oneshot => 'Vue une seule fois, puis détruite',
    CardType.oneOfOne => 'Exclusive : un seul destinataire, à jamais',
    CardType.hot => 'Fenêtre courte, mise en avant si ouverte vite',
    CardType.bereal => 'Instant brut, capturé dans la fenêtre imposée',
  };
}

class CardModel {
  const CardModel({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.frontPath,
    required this.backPath,
    this.viewDurationSeconds,
    required this.createdAt,
  });

  final String id;
  final String ownerId;
  final CardType type;
  final String frontPath;
  final String backPath;

  /// Durée de visionnage (Oneshot uniquement, 1 à 10 s, défaut 3).
  final int? viewDurationSeconds;
  final DateTime createdAt;

  factory CardModel.fromJson(Map<String, dynamic> json) => CardModel(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    type: CardType.fromDb(json['card_type'] as String),
    frontPath: json['front_path'] as String,
    backPath: json['back_path'] as String,
    viewDurationSeconds: json['view_duration_seconds'] as int?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

class CardDelivery {
  const CardDelivery({
    required this.id,
    required this.cardId,
    required this.recipientId,
    required this.deliveredAt,
    this.firstViewedAt,
    this.destroyedAt,
    this.hotBoosted = false,
    this.card,
  });

  final String id;
  final String cardId;
  final String recipientId;
  final DateTime deliveredAt;
  final DateTime? firstViewedAt;
  final DateTime? destroyedAt;

  /// Hot : mise en avant privée chez le destinataire (jamais publique).
  final bool hotBoosted;
  final CardModel? card;

  factory CardDelivery.fromJson(Map<String, dynamic> json) => CardDelivery(
    id: json['id'] as String,
    cardId: json['card_id'] as String,
    recipientId: json['recipient_id'] as String,
    deliveredAt: DateTime.parse(json['delivered_at'] as String),
    firstViewedAt: json['first_viewed_at'] == null
        ? null
        : DateTime.parse(json['first_viewed_at'] as String),
    destroyedAt: json['destroyed_at'] == null
        ? null
        : DateTime.parse(json['destroyed_at'] as String),
    hotBoosted: json['hot_boosted'] as bool? ?? false,
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
  );
}
