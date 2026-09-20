import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/cards/send/share_plan.dart';
import '../../features/conversations/conversations_repository.dart';
import '../../features/pulse/pulse_repository.dart';
import '../supabase_providers.dart';

/// **Le repartage d'un contenu existant** (story, publication) vers ce que
/// l'écran « À qui ? » a rendu en mode repartage.
///
/// Un repartage ne copie rien : il ajoute des **chemins** vers l'unique
/// média (`docs/stockage-et-acces.md`). Mais il n'a pas la même forme selon
/// ce qu'on partage et à qui :
///
/// - une **publication vers un ami** : *« partager, c'est ajouter au feed de
///   l'autre — pas lui envoyer »* (`CLAUDE.md`, Jay 2026-09-11). Elle est
///   **ajoutée à son feed** (`add_to_feed`), anonymement jusqu'à ce qu'il
///   like ; rien n'arrive dans le chat ;
/// - une publication vers un **groupe**, ou une **story** vers qui que ce
///   soit : dans le chat (`share_content`), comme avant.
///
/// Un seul exemplaire de cette boucle, pour les deux visionneuses.
class ContentRepost {
  const ContentRepost(this.ref);
  final Ref ref;

  /// Rend la phrase à montrer. Une destination qui échoue ne bloque pas les
  /// autres.
  Future<String> toPlan(
    String contentId,
    SharePlan plan, {
    required bool isPublication,
  }) async {
    final client = ref.read(supabaseProvider);
    final conversations = ref.read(conversationsRepositoryProvider);
    var atteints = 0;
    var echecs = 0;

    // Les amis : au feed, en un seul appel.
    final amis = <String>[
      if (isPublication)
        for (final c in plan.conversations)
          if (c.peerId != null) c.peerId!,
    ];
    if (amis.isNotEmpty) {
      try {
        atteints += await ref
            .read(pulseRepositoryProvider)
            .addToFeed(contentId, amis);
      } catch (_) {
        echecs++;
      }
    }

    // Les groupes (et tout, pour une story) : dans le chat.
    for (final c in plan.conversations) {
      if (isPublication && c.peerId != null) continue;
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
    if (atteints == 0) return 'Déjà partagé avec eux.';
    final base = isPublication
        ? 'Ajouté au feed de $atteints personne${atteints > 1 ? 's' : ''}.'
        : 'Partagé à $atteints personne${atteints > 1 ? 's' : ''}.';
    return echecs > 0 ? '$base ($echecs en échec)' : base;
  }
}

final contentRepostProvider = Provider((ref) => ContentRepost(ref));
