import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';

/// L'état d'un contenu vis-à-vis des likes : le compte, et « aimé par moi ».
class LikeState {
  const LikeState({required this.count, required this.liked});
  final int count;
  final bool liked;

  LikeState get toggled =>
      LikeState(count: liked ? count - 1 : count + 1, liked: !liked);

  @override
  bool operator ==(Object other) =>
      other is LikeState && other.count == count && other.liked == liked;

  @override
  int get hashCode => Object.hash(count, liked);
}

/// Quelqu'un qui a aimé.
class Liker {
  const Liker({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    required this.likedAt,
  });
  final String id;
  final String displayName;
  final String? avatarUrl;
  final DateTime likedAt;
}

/// **Les likes, un seul magasin** : une carte contenu → état, remplie par
/// lots ([load]) et modifiée à l'écriture ([toggle], optimiste). Toutes les
/// cellules — grille, fil du profil, plein écran, plus tard le feed — lisent
/// la même carte : deux écrans ne peuvent pas afficher deux comptes
/// différents pour le même contenu.
class LikesStore extends Notifier<Map<String, LikeState>> {
  final _pending = <String>{};

  @override
  Map<String, LikeState> build() => const {};

  /// Charge les états manquants de [ids], en un aller-retour.
  Future<void> load(Iterable<String> ids) async {
    final missing = ids
        .where((id) => !state.containsKey(id) && !_pending.contains(id))
        .toSet()
        .toList();
    if (missing.isEmpty) return;
    _pending.addAll(missing);
    try {
      final rows = await ref
          .read(supabaseProvider)
          .rpc('content_likes_summary', params: {'p_ids': missing});
      final next = Map<String, LikeState>.of(state);
      for (final r in rows as List) {
        final row = r as Map<String, dynamic>;
        next[row['content_id'] as String] = LikeState(
          count: row['likes'] as int? ?? 0,
          liked: row['liked'] as bool? ?? false,
        );
      }
      state = next;
    } finally {
      _pending.removeAll(missing);
    }
  }

  /// Aimer / ne plus aimer. L'écran change tout de suite ; le serveur a le
  /// dernier mot — et en cas d'échec, on revient.
  Future<void> toggle(String contentId) async {
    final before = state[contentId] ?? const LikeState(count: 0, liked: false);
    state = {...state, contentId: before.toggled};
    try {
      final rows = await ref
          .read(supabaseProvider)
          .rpc('toggle_like', params: {'p_content_id': contentId});
      final row = (rows as List).first as Map<String, dynamic>;
      state = {
        ...state,
        contentId: LikeState(
          count: row['likes'] as int? ?? 0,
          liked: row['liked'] as bool? ?? false,
        ),
      };
    } catch (_) {
      state = {...state, contentId: before};
      rethrow;
    }
  }

  /// Qui a aimé — pour qui peut voir le contenu.
  Future<List<Liker>> likers(String contentId) async {
    final rows = await ref
        .read(supabaseProvider)
        .rpc('content_likers', params: {'p_content_id': contentId});
    return [
      for (final r in rows as List)
        Liker(
          id: (r as Map<String, dynamic>)['id'] as String,
          displayName: r['display_name'] as String? ?? '',
          avatarUrl: r['avatar_url'] as String?,
          likedAt: DateTime.parse(r['liked_at'] as String),
        ),
    ];
  }
}

final likesStoreProvider = NotifierProvider<LikesStore, Map<String, LikeState>>(
  LikesStore.new,
);
