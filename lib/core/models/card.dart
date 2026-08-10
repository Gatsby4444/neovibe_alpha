import 'package:flutter/material.dart';

/// Types de Cards — énumération extensible (spec 4.8.1, mécaniques V2 du
/// 2026-07-11 ; **refonte du 2026-08-10**).
///
/// Refonte demandée par Jay le 2026-08-10 :
/// - **Mono supprimée** — une Card classique peut désormais n'avoir QU'UNE
///   face (bouton « Passer » à la prise du verso). Le nombre de faces est une
///   propriété de la Card, plus un type à part.
/// - **Hot supprimée** définitivement, contenu et mécanique compris.
/// - **One of One n'est plus un type choisi** : il s'applique AUTOMATIQUEMENT
///   à l'envoi quand la Card part à un seul destinataire sans être publiée
///   (voir `CardSendScreen`). Le type existe donc toujours en base et porte
///   toujours son style or — il ne se choisit simplement plus à la capture.
enum CardType {
  standard,
  oneshot,
  oneOfOne,
  bereal;

  /// Les valeurs `mono` et `hot` restent lisibles : la base de dev a été
  /// convertie (migration `cards_drop_mono_hot`), mais un client à jour peut
  /// encore croiser une ligne héritée. Une mono devient une `standard` à une
  /// face — ce que le nouveau format sait exprimer nativement.
  static CardType fromDb(String value) => switch (value) {
    'standard' || 'mono' || 'hot' => CardType.standard,
    'oneshot' => CardType.oneshot,
    'one_of_one' => CardType.oneOfOne,
    'bereal' => CardType.bereal,
    _ => CardType.standard,
  };

  String get dbValue => switch (this) {
    CardType.standard => 'standard',
    CardType.oneshot => 'oneshot',
    CardType.oneOfOne => 'one_of_one',
    CardType.bereal => 'bereal',
  };

  /// Tag textuel visible sur la Vibe (spec 4.8.1 ; « One of One » depuis la
  /// consigne Jay du 2026-07-12).
  ///
  /// Depuis le 2026-08-10, le nom PUBLIC de l'objet est « Vibe » — le code et
  /// la base gardent `card` (décision de Jay : renommage d'interface seulement).
  String get tag => switch (this) {
    CardType.standard => 'Vibe',
    CardType.oneshot => 'Oneshot',
    CardType.oneOfOne => 'One of One',
    CardType.bereal => 'BeReal',
  };

  /// Types pouvant être marqués « sauvegardables » par le créateur
  /// (jamais One of One : son exclusivité est le format lui-même).
  bool get canBeSaveable => this != CardType.oneOfOne;

  /// Couleur signature du type — code couleur validé par Jay (2026-07-11) :
  /// standard blanc éclatant, Oneshot bleu/magenta électrique, 1/1 or (inchangé),
  /// BeReal vert nature clair/turquoise.
  Color get color => switch (this) {
    CardType.standard => const Color(0xFFFFFFFF), // blanc éclatant
    CardType.oneshot => const Color(0xFF2979FF), // bleu électrique
    CardType.oneOfOne => const Color(0xFFD4AF37), // or — ne pas changer
    CardType.bereal => const Color(0xFF40E0D0), // turquoise
  };

  /// Couleur du type **adaptée au thème** (2026-08-10).
  ///
  /// Le blanc éclatant de la Card classique est sa signature sur fond sombre —
  /// et rigoureusement invisible sur fond clair. En thème clair, et là
  /// seulement, il devient un violet profond neutre. Les autres types ne
  /// bougent pas : ils sont lisibles des deux côtés.
  ///
  /// À utiliser partout où la couleur se pose sur l'habillage de l'app. Sur
  /// une photo ou un aperçu caméra — toujours sombres — garder [color].
  Color displayColor(BuildContext context) =>
      this == CardType.standard &&
          Theme.of(context).brightness == Brightness.light
      ? const Color(0xFF3B3748)
      : color;

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
    CardType.bereal => 'L\'instant imposé du jour, sans mise en scène',
  };

  /// Les types que l'utilisateur peut choisir à la création.
  ///
  /// Depuis la refonte du 2026-08-10, il n'en reste que **deux** : le BeReal
  /// est déclenché par notification, et le One of One s'applique tout seul à
  /// l'envoi (un destinataire, pas de publication).
  static List<CardType> get selectable => [CardType.standard, CardType.oneshot];

  /// Ce type impose-t-il DEUX faces ?
  ///
  /// Le Oneshot capture les deux caméras d'un même déclenché et le BeReal est
  /// un format contraint : leur verso n'est pas optionnel. Une Card classique,
  /// elle, peut désormais s'arrêter à une face (bouton « Passer »), et une
  /// One of One hérite du nombre de faces de la Card capturée.
  bool get requiresTwoFaces =>
      this == CardType.oneshot || this == CardType.bereal;
}

class CardModel {
  const CardModel({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.frontPath,
    this.backPath,
    this.viewDurationSeconds,
    this.maxViews,
    this.encrypted = false,
    this.saveable = false,
    this.imported = false,
    this.frontIsVideo = false,
    this.backIsVideo = false,
    this.scrubbable = false,
    required this.createdAt,
  });

  final String id;
  final String ownerId;
  final CardType type;
  final String frontPath;

  /// Null pour une Card à face unique (verso « passé » à la prise).
  final String? backPath;

  /// Card à une seule face : pas de retournement, seulement le jeu d'angle.
  /// C'est le contenu qui le dit, plus le type (refonte du 2026-08-10).
  bool get singleFace => backPath == null;

  /// Durée de lecture par vue en secondes (null = illimitée). Défaut 10 s.
  final int? viewDurationSeconds;

  /// Nombre de vues côté destinataire (1-5, null = illimité). Défaut 2.
  /// Ne s'applique qu'en chat : la bibliothèque est toujours illimitée.
  final int? maxViews;

  /// Les faces sont chiffrees au repos (depuis le 2026-08-10). Le clair ne
  /// s'obtient qu'avec la cle, que le serveur ne rend qu'en decomptant une vue
  /// (`open_card_media`). Faux pour les Vibes creees avant ce changement, qui
  /// continuent de s'afficher directement.
  final bool encrypted;

  /// Les destinataires peuvent l'enregistrer dans leurs Enregistrements.
  final bool saveable;

  /// Au moins une face vient de la galerie (pas d'une capture en direct) —
  /// signalé par un petit logo galerie sur le container en chat.
  final bool imported;

  /// Nature de chaque face : photo ou vidéo (mode vidéo, consigne Jay
  /// 2026-07-12). Une face vidéo se lit en entier — la durée de visionnage
  /// ne s'applique qu'aux faces photo.
  final bool frontIsVideo;
  final bool backIsVideo;

  /// Le destinataire peut contrôler la barre de lecture des vidéos
  /// (choisi par le créateur à l'envoi ; défaut : barre intouchable).
  final bool scrubbable;
  final DateTime createdAt;

  factory CardModel.fromJson(Map<String, dynamic> json) => CardModel(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    type: CardType.fromDb(json['card_type'] as String),
    frontPath: json['front_path'] as String,
    backPath: json['back_path'] as String?,
    viewDurationSeconds: json['view_duration_seconds'] as int?,
    maxViews: json['max_views'] as int?,
    encrypted: json['encrypted'] as bool? ?? false,
    saveable: json['saveable'] as bool? ?? false,
    imported: json['imported'] as bool? ?? false,
    frontIsVideo: json['front_is_video'] as bool? ?? false,
    backIsVideo: json['back_is_video'] as bool? ?? false,
    scrubbable: json['scrubbable'] as bool? ?? false,
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

  /// Vues déjà consommées par le destinataire.
  final int viewCount;

  /// Replay : demandé par le destinataire, accordé par l'émetteur (+1 vue).
  final DateTime? replayRequestedAt;
  final DateTime? replayGrantedAt;
  final CardModel? card;

  /// Vues restantes pour ce destinataire (null = illimité).
  int? remainingViews(CardModel card) {
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
