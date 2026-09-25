import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connections_repository.dart';
import '../models/profile.dart';
import '../supabase_providers.dart';

/// Motifs de signalement.
///
/// Volontairement **courts et peu nombreux**. Une liste longue donne
/// l'illusion de la précision et fait hésiter ; ce qu'on veut, c'est qu'un
/// signalement soit rapide à faire. La nuance viendra du champ libre.
enum ReportReason {
  inappropriate('Contenu inapproprié'),
  harassment('Harcèlement'),
  impersonation('Usurpation d\'identité'),
  minor('Met en danger un mineur'),
  other('Autre');

  const ReportReason(this.label);
  final String label;

  String get dbValue => name;
}

/// **Ce qu'on signale.** Quatre objets, quatre tables côté serveur — un
/// signalement porte sur UN objet, jamais sur « un contenu » au sens vague.
sealed class ReportTarget {
  const ReportTarget();
}

/// Un contenu du socle (story, publication).
class ContentReportTarget extends ReportTarget {
  const ContentReportTarget(this.contentId);
  final String contentId;
}

/// Une personne.
class ProfileReportTarget extends ReportTarget {
  const ProfileReportTarget(this.userId);
  final String userId;
}

/// Une Vibe posée dans un Drop (2026-09-25).
class DropVibeReportTarget extends ReportTarget {
  const DropVibeReportTarget(this.vibeId);
  final String vibeId;
}

/// Une Vibe reçue dans un chat (2026-09-25). Jusqu'ici elle ne se signalait
/// que par le profil de son expéditeur.
class SentVibeReportTarget extends ReportTarget {
  const SentVibeReportTarget(this.cardId);
  final String cardId;
}

/// Une soirée — son affiche et sa description (2026-09-25).
class EventReportTarget extends ReportTarget {
  const EventReportTarget(this.eventId);
  final String eventId;
}

/// Signalement et blocage — le socle de modération (2026-08-11).
///
/// Point signalé comme **bloquant** avant l'ouverture de la propagation hors
/// cercle : tant qu'un contenu reste entre amis, le cercle social fait la
/// modération. Dès qu'il peut atteindre un inconnu à plusieurs sauts, ça ne se
/// défend plus.
class ModerationRepository {
  ModerationRepository(this.ref);
  final Ref ref;

  /// Signale un contenu. Le serveur vérifie que l'appelant a bien le droit de
  /// le voir — on ne signale pas ce qu'on ne peut pas voir.
  Future<void> reportContent(
    String contentId,
    ReportReason reason, {
    String? details,
  }) async {
    await ref.read(supabaseProvider).from('content_reports').insert({
      'content_id': contentId,
      'reporter_id': ref.read(currentUserIdProvider),
      'reason': reason.dbValue,
      if (details != null && details.isNotEmpty) 'details': details,
    });
  }

  /// Signale une cible, quelle qu'elle soit. Pour les Vibes, l'auteur est
  /// relevé par le serveur (`report_drop_vibe` / `report_sent_vibe`), jamais
  /// fourni par l'app ; un doublon n'y est pas une erreur.
  Future<void> report(
    ReportTarget target,
    ReportReason reason, {
    String? details,
  }) async {
    final client = ref.read(supabaseProvider);
    final d = details != null && details.isNotEmpty ? details : null;
    switch (target) {
      case ContentReportTarget(:final contentId):
        await reportContent(contentId, reason, details: d);
      case ProfileReportTarget(:final userId):
        await reportProfile(userId, reason, details: d);
      case DropVibeReportTarget(:final vibeId):
        await client.rpc(
          'report_drop_vibe',
          params: {
            'p_vibe_id': vibeId,
            'p_reason': reason.dbValue,
            'p_details': d,
          },
        );
      case EventReportTarget(:final eventId):
        await client.rpc(
          'report_event',
          params: {
            'p_event': eventId,
            'p_reason': reason.dbValue,
            'p_details': d,
          },
        );
      case SentVibeReportTarget(:final cardId):
        await client.rpc(
          'report_sent_vibe',
          params: {
            'p_card_id': cardId,
            'p_reason': reason.dbValue,
            'p_details': d,
          },
        );
    }
  }

  Future<void> reportProfile(
    String targetId,
    ReportReason reason, {
    String? details,
  }) async {
    await ref.read(supabaseProvider).from('profile_reports').insert({
      'target_id': targetId,
      'reporter_id': ref.read(currentUserIdProvider),
      'reason': reason.dbValue,
      if (details != null && details.isNotEmpty) 'details': details,
    });
  }

  /// Bloque une personne. L'effet est **réciproque** : plus aucun des deux ne
  /// voit le contenu de l'autre, et aucun relais ne peut contourner le
  /// blocage. Celui qui est bloqué n'en est pas informé — c'est le propre d'un
  /// blocage utile.
  Future<void> block(String userId) async {
    await ref
        .read(supabaseProvider)
        .rpc('block_user', params: {'p_user_id': userId});
    _rafraichir();
  }

  Future<void> unblock(String userId) async {
    await ref
        .read(supabaseProvider)
        .rpc('unblock_user', params: {'p_user_id': userId});
    _rafraichir();
  }

  /// ⚠️ **Bloquer change le graphe d'amis — il faut le dire aux vues.**
  ///
  /// Constaté par Jay le 2026-08-27 : *« lorsque j'ai bloqué mimi elle
  /// n'apparaissait plus dans la liste des amis mais le compteur des amis
  /// restait à 5 »*. Deux vues, deux sources, une seule rafraîchie.
  ///
  /// ⚠️ Et le flux lui-même n'est pas fiable ici : une **suppression** de ligne
  /// n'est pas toujours diffusée par le temps réel Postgres — or `block_user`
  /// **supprime** la connexion. On réinvalide donc la source, au lieu d'espérer
  /// qu'elle se réveille.
  ///
  /// ⚠️ **L'invalidation appartient à l'ÉCRITURE** (règle de `CLAUDE.md`) :
  /// posée ici, tout chemin de blocage en profite — le menu « … » d'une story,
  /// celui d'une Vibe, celui d'un profil.
  ///
  /// ## ⚠️ Ce qui a été RETIRÉ d'ici le 2026-08-28, et pourquoi c'est un gain
  ///
  /// Le compteur d'amis et la synchronisation du carnet ne sont plus rappelés
  /// ici. Ils appartiennent à *« le graphe d'amis a changé »*, pas à *« j'ai
  /// bloqué quelqu'un »* — et tant qu'ils vivaient dans chaque écriture, chacune
  /// en tenait une version différente. Le retrait d'ami n'en avait aucune : même
  /// symptôme, signalé le lendemain de cette correction-ci.
  ///
  /// La règle est maintenant à **un seul endroit**, déclenchée par le graphe
  /// lui-même : `features/proximity/net/friend_book_watcher.dart`.
  void _rafraichir() {
    ref.invalidate(blockedProfilesProvider);
    ref.invalidate(connectionsStreamProvider);
  }
}

final moderationRepositoryProvider = Provider(ModerationRepository.new);

/// Les personnes que J'AI bloquées. Personne ne peut lire la liste des
/// blocages d'autrui.
final blockedProfilesProvider = FutureProvider<List<Profile>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('blocks')
      .select('blocked_id, profiles!blocks_blocked_id_fkey(*)')
      .eq('blocker_id', me)
      .order('created_at', ascending: false);
  return rows
      .map((r) => Profile.fromJson(r['profiles'] as Map<String, dynamic>))
      .toList();
});

/// Ai-je bloqué cette personne ?
final isBlockedProvider = FutureProvider.family<bool, String>((ref, id) async {
  final blocked = await ref.watch(blockedProfilesProvider.future);
  return blocked.any((p) => p.id == id);
});
