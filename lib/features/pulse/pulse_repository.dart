import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/likes.dart';
import '../../core/location/anchor.dart';
import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';

/// **Les trois modes du fil** (Jay, 2026-09-20) — le sélecteur en haut de
/// chaque fil, comme celui de la galerie mais en menu déroulant.
enum FeedMode {
  /// Les croisés (3 jours), ce que mes amis m'ont ajouté, et ce qui a été
  /// localisé près de moi.
  tout('Tout'),

  /// Seulement ce que mes amis m'ont ajouté.
  amis('Amis'),

  /// Seulement ce qui a été localisé à moins d'un kilomètre de moi.
  autour('Autour de moi');

  const FeedMode(this.label);
  final String label;

  String get rpcValue => switch (this) {
    FeedMode.tout => 'all',
    FeedMode.amis => 'friends',
    FeedMode.autour => 'around',
  };
}

/// Ce qu'on demande au serveur : une nature (nulle = toutes), un mode, et
/// où je suis (nul = pas de source « autour »).
typedef FeedQuery = ({LibraryKind? kind, FeedMode mode, ContentAnchor? at});

/// **Le feed** — la fonction `feed_items` du serveur, telle quelle : les
/// candidats des trois sources, déjà filtrés par le seul juge des droits,
/// ordonnés par `feed_rank` (aujourd'hui le plus récent d'abord ; la
/// pertinence se branchera là-bas, pas ici). Les lignes sont des
/// `library_items` avec leurs médias : le même modèle que le profil.
final feedItemsProvider = FutureProvider.family<List<LibraryItem>, FeedQuery>((
  ref,
  q,
) async {
  final rows = await ref
      .watch(supabaseProvider)
      .rpc(
        'feed_items',
        params: {
          'p_kind': q.kind?.dbValue,
          'p_mode': q.mode.rpcValue,
          'p_lat': q.at?.lat,
          'p_lng': q.at?.lng,
        },
      )
      .select(LibraryItem.select);
  return [
    for (final r in rows as List)
      LibraryItem.fromJson(r as Map<String, dynamic>),
  ];
});

/// **Qui m'a ajouté ce contenu** — révélé par le serveur SEULEMENT si je l'ai
/// liké (`feed_adders`) ; nul sinon, ou si personne ne me l'a ajouté. Ne
/// demande rien tant que le like n'est pas posé.
final revealedAdderProvider = FutureProvider.family<String?, String>((
  ref,
  contentId,
) async {
  final liked = ref.watch(likesStoreProvider)[contentId]?.liked ?? false;
  if (!liked) return null;
  final rows = await ref
      .watch(supabaseProvider)
      .rpc(
        'feed_adders',
        params: {
          'p_content_ids': [contentId],
        },
      );
  final list = rows as List;
  if (list.isEmpty) return null;
  return (list.first as Map<String, dynamic>)['display_name'] as String?;
});

class PulseRepository {
  const PulseRepository(this.ref);
  final Ref ref;

  /// Ajoute un contenu au feed de ces amis — anonymement. Rend combien
  /// l'ont reçu (un ami qui l'avait déjà ne compte pas).
  Future<int> addToFeed(String contentId, List<String> friendIds) async {
    final n = await ref
        .read(supabaseProvider)
        .rpc(
          'add_to_feed',
          params: {'p_content_id': contentId, 'p_recipient_ids': friendIds},
        );
    return (n as int?) ?? 0;
  }
}

final pulseRepositoryProvider = Provider((ref) => PulseRepository(ref));
