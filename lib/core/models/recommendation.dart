import 'profile.dart';

enum RecommendationStatus {
  requested,
  forwarded,
  accepted,
  declined,
  expired;

  static RecommendationStatus fromDb(String value) =>
      RecommendationStatus.values.byName(value);
}

/// Recommandation A→B→C : B (requester) demande à A (intermediary)
/// de le mettre en relation avec C (target, choisi par A à la transmission).
class Recommendation {
  const Recommendation({
    required this.id,
    required this.requesterId,
    required this.intermediaryId,
    this.targetId,
    required this.targetHint,
    required this.status,
    required this.createdAt,
    this.requester,
    this.intermediary,
    this.target,
  });

  final String id;
  final String requesterId;
  final String intermediaryId;
  final String? targetId;
  final String targetHint;
  final RecommendationStatus status;
  final DateTime createdAt;
  final Profile? requester;
  final Profile? intermediary;
  final Profile? target;

  factory Recommendation.fromJson(Map<String, dynamic> json) => Recommendation(
    id: json['id'] as String,
    requesterId: json['requester_id'] as String,
    intermediaryId: json['intermediary_id'] as String,
    targetId: json['target_id'] as String?,
    targetHint: json['target_hint'] as String,
    status: RecommendationStatus.fromDb(json['status'] as String),
    createdAt: DateTime.parse(json['created_at'] as String),
    requester: json['requester'] == null
        ? null
        : Profile.fromJson(json['requester'] as Map<String, dynamic>),
    intermediary: json['intermediary'] == null
        ? null
        : Profile.fromJson(json['intermediary'] as Map<String, dynamic>),
    target: json['target'] == null
        ? null
        : Profile.fromJson(json['target'] as Map<String, dynamic>),
  );
}
