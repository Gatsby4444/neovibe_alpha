import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/story.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';

/// Toutes les stories vivantes que j'ai le droit de voir.
///
/// C'est la RLS qui décide, pas le client : `stories_select_visible` laisse
/// passer les miennes, celles de mes amis, et — si l'auteur a activé « stories
/// publiques » — celles des personnes que j'ai croisées physiquement dans les
/// dernières 24 h (croisement certifié, deux signatures Ed25519 vérifiées
/// côté serveur). Une requête suffit donc pour les deux fils ; on ne les
/// sépare ensuite que pour l'affichage.
final _visibleStoriesProvider = FutureProvider<List<Story>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('stories')
      .select('*, cards(*), profiles!stories_owner_id_fkey(*)')
      .gt('expires_at', DateTime.now().toUtc().toIso8601String())
      .order('created_at', ascending: false);
  return rows.map(Story.fromJson).toList();
});

/// Regroupe les stories par auteur, plus récent d'abord. L'auteur sans profil
/// joint est écarté : sans pseudo ni avatar, il n'y a rien à afficher.
List<StoryRing> _ring(List<Story> stories) {
  final byOwner = <String, List<Story>>{};
  for (final story in stories) {
    if (story.owner == null) continue;
    byOwner.putIfAbsent(story.ownerId, () => []).add(story);
  }
  final rings = byOwner.values
      .map((list) => StoryRing(owner: list.first.owner!, stories: list))
      .toList();
  rings.sort((a, b) => b.latestAt.compareTo(a.latestAt));
  return rings;
}

/// Bandeau du **Cercle** : mes stories et celles de mes amis.
final friendStoriesProvider = FutureProvider<List<StoryRing>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final stories = await ref.watch(_visibleStoriesProvider.future);
  final friends = ref
      .watch(fullConnectionsProvider)
      .map((c) => c.peerIdFor(me))
      .toSet();
  return _ring(
    stories
        .where((s) => s.ownerId == me || friends.contains(s.ownerId))
        .toList(),
  );
});

/// Bandeau du **Ping** : les stories des personnes croisées qui ne sont PAS
/// mes amis. Le tri se fait ici et non côté serveur — la RLS a déjà écarté
/// tout ce que je n'ai pas le droit de voir, il ne reste qu'à séparer les
/// deux fils pour ne pas afficher deux fois les mêmes personnes.
final crossedStoriesProvider = FutureProvider<List<StoryRing>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final stories = await ref.watch(_visibleStoriesProvider.future);
  final friends = ref
      .watch(fullConnectionsProvider)
      .map((c) => c.peerIdFor(me))
      .toSet();
  return _ring(
    stories
        .where((s) => s.ownerId != me && !friends.contains(s.ownerId))
        .toList(),
  );
});

class StoriesRepository {
  StoriesRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  /// Publie une Card existante en story (24 h). `upsert` sur la contrainte
  /// (owner_id, card_id) : republier la même card ne crée pas de doublon.
  Future<void> publish(String cardId) async {
    final me = _client.auth.currentUser!.id;
    await _client.from('stories').upsert({
      'owner_id': me,
      'card_id': cardId,
    }, onConflict: 'owner_id,card_id');
    _invalidate();
  }

  Future<void> remove(String storyId) async {
    await _client.from('stories').delete().eq('id', storyId);
    _invalidate();
  }

  /// Bascule « stories publiques » : les croisés de moins de 24 h voient
  /// mes stories, en plus de mes amis.
  Future<void> setStoriesPublic(bool value) async {
    final me = _client.auth.currentUser!.id;
    await _client
        .from('profiles')
        .update({'stories_public': value})
        .eq('id', me);
    ref.invalidate(myProfileProvider);
  }

  void _invalidate() {
    ref.invalidate(_visibleStoriesProvider);
  }
}

final storiesRepositoryProvider = Provider(StoriesRepository.new);
