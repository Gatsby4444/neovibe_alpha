import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/cards/send/share_plan.dart';
import '../../features/conversations/conversations_repository.dart';
import '../supabase_providers.dart';

/// **Le repartage d'un contenu existant** (story, publication) vers ce que
/// l'écran « À qui ? » a rendu en mode repartage.
///
/// Un repartage ne copie rien : `share_content` ajoute des **chemins** vers
/// l'unique média (`docs/stockage-et-acces.md`). Il ne va que dans des chats —
/// le plan rendu en mode repartage ne contient que des conversations, et le
/// DM d'un ami avec qui on n'a jamais discuté s'ouvre ici, à l'envoi.
///
/// Un seul exemplaire de cette boucle, pour les deux visionneuses : avant le
/// 2026-09-14, chacune avait sa copie de la liste ET de l'appel.
class ContentRepost {
  const ContentRepost(this.ref);
  final Ref ref;

  /// Rend la phrase à montrer : combien de personnes atteintes, ou « déjà
  /// partagé ». Une conversation qui échoue ne bloque pas les autres.
  Future<String> toPlan(String contentId, SharePlan plan) async {
    final client = ref.read(supabaseProvider);
    final conversations = ref.read(conversationsRepositoryProvider);
    var atteints = 0;
    var echecs = 0;
    for (final c in plan.conversations) {
      try {
        final convId =
            c.conversationId ??
            await conversations.getOrCreateDirect(c.peerId!);
        final added = await client.rpc(
          'share_content',
          params: {'p_content_id': contentId, 'p_conversation_id': convId},
        );
        atteints += (added as int?) ?? 0;
      } catch (_) {
        echecs++;
      }
    }
    if (echecs > 0 && atteints == 0) return 'Le partage a échoué.';
    if (atteints == 0) return 'Déjà partagé dans ces conversations.';
    final base = 'Partagé à $atteints personne${atteints > 1 ? 's' : ''}.';
    return echecs > 0 ? '$base ($echecs conversation(s) en échec)' : base;
  }
}

final contentRepostProvider = Provider((ref) => ContentRepost(ref));
