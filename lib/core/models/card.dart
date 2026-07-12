import 'package:flutter/material.dart';

/// Types de Cards — énumération extensible (spec 4.8.1, mécaniques V2 du
/// 2026-07-11 : vues/durée paramétrables, Hot sans trace, Oneshot = double
/// capture simultanée).
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

  /// Tag textuel visible sur la Card (spec 4.8.1 ; « One of One » depuis la
  /// consigne Jay du 2026-07-12).
  String get tag => switch (this) {
    CardType.standard => 'Card',
    CardType.oneshot => 'Oneshot',
    CardType.oneOfOne => 'One of One',
    CardType.hot => 'Hot',
    CardType.bereal => 'BeReal',
  };

  /// Types pouvant être marqués « sauvegardables » par le créateur
  /// (jamais Hot ni One of One).
  bool get canBeSaveable => switch (this) {
    CardType.standard || CardType.oneshot || CardType.bereal => true,
    CardType.hot || CardType.oneOfOne => false,
  };

  /// Couleur signature du type — code couleur validé par Jay (2026-07-11) :
  /// standard blanc éclatant, Oneshot bleu/magenta électrique, 1/1 or (inchangé),
  /// Hot rouge Torino, BeReal vert nature clair/turquoise.
  Color get color => switch (this) {
    CardType.standard => const Color(0xFFFFFFFF), // blanc éclatant
    CardType.oneshot => const Color(0xFF2979FF), // bleu électrique
    CardType.oneOfOne => const Color(0xFFD4AF37), // or — ne pas changer
    CardType.hot => const Color(0xFFC8102E), // rouge Torino
    CardType.bereal => const Color(0xFF40E0D0), // turquoise
  };

  /// Dégradé signature (Oneshot et BeReal) — null = couleur unie.
  Gradient? get gradient => switch (this) {
    CardType.oneshot => const LinearGradient(
      colors: [
        Color(0xFF2979FF),
        Color(0xFFE040FB),
      ], // bleu → magenta électrique
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    CardType.bereal => const LinearGradient(
      colors: [Color(0xFF7ED957), Color(0xFF40E0D0)], // vert nature → turquoise
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    _ => null,
  };

  String get description => switch (this) {
    CardType.standard =>
      'Vues et durée à ta main, trace 24 h dans le chat, replay sur ton accord',
    CardType.oneshot =>
      'Avant + arrière capturés d\'un seul déclenché, sinon comme une classique',
    CardType.oneOfOne => 'Exclusive : un seul destinataire, à jamais',
    CardType.hot =>
      'Une seule vue, temps limité — le contenu disparaît, le container reste',
    CardType.bereal => 'L\'instant imposé du jour, sans mise en scène',
  };

  /// Les types que l'utilisateur peut choisir à la création
  /// (BeReal est déclenchée par notification, pas par le menu).
  static List<CardType> get selectable => [
    CardType.standard,
    CardType.oneshot,
    CardType.oneOfOne,
    CardType.hot,
  ];

  /// Vues/durée paramétrables par le créateur (Hot : figé à 1 vue courte).
  bool get hasConfigurableViews => this != CardType.hot;
}

class CardModel {
  const CardModel({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.frontPath,
    required this.backPath,
    this.viewDurationSeconds,
    this.maxViews,
    this.saveable = false,
    required this.createdAt,
  });

  final String id;
  final String ownerId;
  final CardType type;
  final String frontPath;
  final String backPath;

  /// Durée de lecture par vue en secondes (null = illimitée). Défaut 10 s.
  final int? viewDurationSeconds;

  /// Nombre de vues côté destinataire (1-5, null = illimité). Défaut 2.
  /// Ne s'applique qu'en chat : la bibliothèque est toujours illimitée.
  final int? maxViews;

  /// Les destinataires peuvent l'enregistrer dans leurs Enregistrements.
  final bool saveable;
  final DateTime createdAt;

  factory CardModel.fromJson(Map<String, dynamic> json) => CardModel(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    type: CardType.fromDb(json['card_type'] as String),
    frontPath: json['front_path'] as String,
    backPath: json['back_path'] as String,
    viewDurationSeconds: json['view_duration_seconds'] as int?,
    maxViews: json['max_views'] as int?,
    saveable: json['saveable'] as bool? ?? false,
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
    this.viewCount = 0,
    this.replayRequestedAt,
    this.replayGrantedAt,
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

  /// Vues déjà consommées par le destinataire.
  final int viewCount;

  /// Replay : demandé par le destinataire, accordé par l'émetteur (+1 vue).
  final DateTime? replayRequestedAt;
  final DateTime? replayGrantedAt;
  final CardModel? card;

  /// Vues restantes pour ce destinataire (null = illimité).
  int? remainingViews(CardModel card) {
    if (card.type == CardType.hot) return viewCount >= 1 ? 0 : 1;
    if (card.maxViews == null) return null;
    final bonus = replayGrantedAt != null ? 1 : 0;
    final remaining = card.maxViews! + bonus - viewCount;
    return remaining < 0 ? 0 : remaining;
  }

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
    viewCount: json['view_count'] as int? ?? 0,
    replayRequestedAt: json['replay_requested_at'] == null
        ? null
        : DateTime.parse(json['replay_requested_at'] as String),
    replayGrantedAt: json['replay_granted_at'] == null
        ? null
        : DateTime.parse(json['replay_granted_at'] as String),
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
  );
}
