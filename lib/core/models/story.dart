import 'card.dart';
import 'profile.dart';

/// Une story EST une Card publiée en story (décision Jay 2026-08-02) : pas de
/// pipeline média séparé, on réutilise la capture et le bucket `cards`.
///
/// Durée de vie 24 h, consultable **sans limite** pendant ce temps — la vue
/// unique reste la règle des Cards envoyées en chat, pas des stories.
class Story {
  const Story({
    required this.id,
    required this.ownerId,
    required this.createdAt,
    required this.expiresAt,
    this.card,
    this.owner,
  });

  final String id;
  final String ownerId;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// Card portée par la story. Null si la RLS ne l'a pas laissée passer —
  /// ne devrait pas arriver, la policy `cards_select_story` suit la même
  /// règle que la story elle-même.
  final CardModel? card;

  /// Auteur, joint pour l'affichage (pastille + pseudo, style Instagram).
  final Profile? owner;

  factory Story.fromJson(Map<String, dynamic> json) => Story(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
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
