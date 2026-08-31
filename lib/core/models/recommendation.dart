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
      other is Recommendation &&
      other.id == id &&
      other.requesterId == requesterId &&
      other.intermediaryId == intermediaryId &&
      other.targetId == targetId &&
      other.targetHint == targetHint &&
      other.status == status &&
      other.createdAt == createdAt &&
      other.requester == requester &&
      other.intermediary == intermediary &&
      other.target == target;

  @override
  int get hashCode => Object.hash(
    id,
    requesterId,
    intermediaryId,
    targetId,
    targetHint,
    status,
    createdAt,
    requester,
    intermediary,
    target,
  );
}
