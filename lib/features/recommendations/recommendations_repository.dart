import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/recommendation.dart';
import '../../core/supabase_providers.dart';

const _selectWithProfiles =
    '*, '
    'requester:profiles!recommendations_requester_id_fkey(*), '
    'intermediary:profiles!recommendations_intermediary_id_fkey(*), '
    'target:profiles!recommendations_target_id_fkey(*)';

/// Demandes que J'AI envoyées (en tant que B).
/// Spec 4.5.5 : jamais de statut négatif visible — on ne montre que
/// "en attente" ou "acceptée" ; refus et expiration restent silencieux.
final myRecommendationRequestsProvider = FutureProvider<List<Recommendation>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('recommendations')
      .select(_selectWithProfiles)
      .eq('requester_id', me)
      .order('created_at', ascending: false);
  return rows
      .map(Recommendation.fromJson)
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
  final rows = await ref
      .watch(supabaseProvider)
      .from('recommendations')
      .select(_selectWithProfiles)
      .eq('intermediary_id', me)
      .eq('status', 'requested')
      .order('created_at', ascending: false);
  return rows.map(Recommendation.fromJson).toList();
});

/// Propositions reçues (en tant que C).
final recommendationProposalsProvider = FutureProvider<List<Recommendation>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('recommendations')
      .select(_selectWithProfiles)
      .eq('target_id', me)
      .eq('status', 'forwarded')
      .order('created_at', ascending: false);
  return rows.map(Recommendation.fromJson).toList();
});

class RecommendationsRepository {
  RecommendationsRepository(this.ref);
  final Ref ref;

  /// B demande à A une mise en relation (C décrit en texte libre).
  Future<void> request(String intermediaryId, String targetHint) async {
    final me = ref.read(currentUserIdProvider)!;
    await ref.read(supabaseProvider).from('recommendations').insert({
      'requester_id': me,
      'intermediary_id': intermediaryId,
      'target_hint': targetHint,
    });
  }

  /// A transmet vers le C qu'il a choisi (plafond 10/mois vérifié serveur).
  Future<void> forward(String recoId, String targetId) => ref
      .read(supabaseProvider)
      .rpc(
        'forward_recommendation',
        params: {'reco_id': recoId, 'chosen_target': targetId},
      );

  Future<void> accept(String recoId) => ref
      .read(supabaseProvider)
      .rpc('accept_recommendation', params: {'reco_id': recoId});

  Future<void> decline(String recoId) => ref
      .read(supabaseProvider)
      .rpc('decline_recommendation', params: {'reco_id': recoId});
}

final recommendationsRepositoryProvider = Provider(
  (ref) => RecommendationsRepository(ref),
);
