import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/nv_api.dart';
import '../../core/models/recommendation.dart';
import '../../core/supabase_providers.dart';

/// Les recommandations d'un rôle (`requester`, `intermediary`, `target`),
/// avec les trois profils, les plus récentes d'abord.
Future<List<Recommendation>> _recommandations(Ref ref, String role) async {
  final rows =
      await ref.watch(nvApiProvider).op('recommendations_list', {
            'p_role': role,
          })
          as List;
  return [
    for (final r in rows) Recommendation.fromJson(r as Map<String, dynamic>),
  ];
}

/// Demandes que J'AI envoyées (en tant que B).
/// Spec 4.5.5 : jamais de statut négatif visible — on ne montre que
/// "en attente" ou "acceptée" ; refus et expiration restent silencieux.
final myRecommendationRequestsProvider = FutureProvider<List<Recommendation>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await _recommandations(ref, 'requester');
  return rows
      .where(
        (r) =>
            r.status == RecommendationStatus.requested ||
            r.status == RecommendationStatus.forwarded ||
            r.status == RecommendationStatus.accepted,
      )
      .toList();
});

/// Demandes à transmettre (en tant qu'intermédiaire A).
final recommendationInboxProvider = FutureProvider<List<Recommendation>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  return _recommandations(ref, 'intermediary');
});

/// Propositions reçues (en tant que C).
final recommendationProposalsProvider = FutureProvider<List<Recommendation>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  return _recommandations(ref, 'target');
});

class RecommendationsRepository {
  RecommendationsRepository(this.ref);
  final Ref ref;

  /// B demande à A une mise en relation (C décrit en texte libre).
  Future<void> request(String intermediaryId, String targetHint) async {
    final me = ref.read(currentUserIdProvider)!;
    await ref.read(nvApiProvider).op('recommendation_create', {
      'requester_id': me,
      'intermediary_id': intermediaryId,
      'target_hint': targetHint,
    });
  }

  /// A transmet vers le C qu'il a choisi (plafond 10/mois vérifié serveur).
  Future<void> forward(String recoId, String targetId) =>
      ref.read(nvApiProvider).op('forward_recommendation', {
        'reco_id': recoId,
        'chosen_target': targetId,
      });

  Future<void> accept(String recoId) =>
      ref.read(nvApiProvider).op('accept_recommendation', {'reco_id': recoId});

  Future<void> decline(String recoId) =>
      ref.read(nvApiProvider).op('decline_recommendation', {'reco_id': recoId});
}

final recommendationsRepositoryProvider = Provider(
  (ref) => RecommendationsRepository(ref),
);
