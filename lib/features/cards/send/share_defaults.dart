import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/supabase_providers.dart';
import '../../connections/friendship.dart';
import 'share_plan.dart';

/// **Mes défauts de partage** — ce qui est coché quand je n'ai rien réglé.
///
/// ## Les trois niveaux (plan §2.4, Jay 2026-09-14)
///
/// Quand je coche un ami, son « Sauvegardable » vient, dans l'ordre :
///
/// 1. **son défaut à lui** — `friend_share_defaults` sur le serveur, visible
///    par moi seul (« pour Léa, toujours sauvegardable ») ;
/// 2. sinon **mon défaut général** — [ShareDefaults.peopleSaveable], ici ;
/// 3. sinon le défaut du produit — non sauvegardable.
///
/// C'est [resolveSaveable] qui applique cet ordre, et c'est une fonction
/// pure : elle se teste.
///
/// ## Un réglage, un propriétaire
///
/// Les deux sur-écrans ⚙︎ (bouton « Défauts ») et l'entrée « Partage » des
/// Réglages écrivent **ici**, et nulle part ailleurs. Les limites de vues et
/// de durée gardent leur propriétaire historique (`defaultMaxViewsProvider`,
/// `defaultViewDurationProvider` dans `prefs.dart`) : les recopier ici aurait
/// fait deux sources pour la même valeur.
@immutable
class ShareDefaults {
  const ShareDefaults({
    this.story = const StoryShare(),
    this.library = const LibraryShare(),
    this.peopleSaveable = false,
  });

  /// Ce que coche « Story » par défaut : palier, partageable, sauvegardable.
  final StoryShare story;

  /// Ce que coche « Bibliothèque » par défaut.
  final LibraryShare library;

  /// « Sauvegardable » pour un ami ou un groupe **sans défaut propre**.
  final bool peopleSaveable;

  ShareDefaults copyWith({
    StoryShare? story,
    LibraryShare? library,
    bool? peopleSaveable,
  }) => ShareDefaults(
    story: story ?? this.story,
    library: library ?? this.library,
    peopleSaveable: peopleSaveable ?? this.peopleSaveable,
  );

  Map<String, dynamic> toJson() => {
    'story': {
      'tier': story.tier.name,
      'shareable': story.shareable,
      'saveable': story.saveable,
    },
    'library': {
      'isPublic': library.isPublic,
      'shareable': library.shareable,
      'saveable': library.saveable,
    },
    'peopleSaveable': peopleSaveable,
  };

  /// Tolérant : une clé absente vaut son défaut. Une préférence écrite par une
  /// version plus récente ne doit pas faire tomber l'écran de partage.
  factory ShareDefaults.fromJson(Map<String, dynamic> json) {
    final s = json['story'] as Map<String, dynamic>? ?? const {};
    final l = json['library'] as Map<String, dynamic>? ?? const {};
    return ShareDefaults(
      story: StoryShare(
        tier: FriendshipTier.fromKey(s['tier'] as String?),
        shareable: s['shareable'] as bool? ?? false,
        saveable: s['saveable'] as bool? ?? false,
      ),
      library: LibraryShare(
        isPublic: l['isPublic'] as bool? ?? false,
        shareable: l['shareable'] as bool? ?? false,
        saveable: l['saveable'] as bool? ?? false,
      ),
      peopleSaveable: json['peopleSaveable'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShareDefaults &&
      other.story.tier == story.tier &&
      other.story.shareable == story.shareable &&
      other.story.saveable == story.saveable &&
      other.library.isPublic == library.isPublic &&
      other.library.shareable == library.shareable &&
      other.library.saveable == library.saveable &&
      other.peopleSaveable == peopleSaveable;

  @override
  int get hashCode => Object.hash(
    story.tier,
    story.shareable,
    story.saveable,
    library.isPublic,
    library.shareable,
    library.saveable,
    peopleSaveable,
  );
}

/// L'ordre des trois niveaux, en une fonction. [perFriend] : les défauts par
/// ami (serveur) ; [general] : mon défaut général.
bool resolveSaveable({
  required String friendId,
  required Map<String, bool> perFriend,
  required bool general,
}) => perFriend[friendId] ?? general;

// ---------------------------------------------------------------------------
// Mes défauts généraux — une préférence, un seul objet
// ---------------------------------------------------------------------------

class ShareDefaultsPref extends Notifier<ShareDefaults> {
  static const _key = 'share_defaults';

  @override
  ShareDefaults build() {
    _load();
    return const ShareDefaults();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      state = ShareDefaults.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Une préférence illisible vaut « aucune » : on garde les défauts du
      // produit plutôt que de bloquer le partage.
    }
  }

  Future<void> set(ShareDefaults value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}

final shareDefaultsProvider =
    NotifierProvider<ShareDefaultsPref, ShareDefaults>(ShareDefaultsPref.new);

// ---------------------------------------------------------------------------
// Les défauts par ami — sur le serveur, propriétaire seul
// ---------------------------------------------------------------------------

/// **La cuisine** des défauts par ami : lit et écrit `friend_share_defaults`.
class FriendShareDefaultsRepository {
  const FriendShareDefaultsRepository(this.ref);
  final Ref ref;

  Future<Map<String, bool>> all() async {
    final me = ref.read(currentUserIdProvider);
    if (me == null) return const {};
    final rows =
        await ref
                .read(supabaseProvider)
                .from('friend_share_defaults')
                .select('friend_id, saveable')
            as List;
    return {
      for (final row in rows)
        (row as Map<String, dynamic>)['friend_id'] as String:
            row['saveable'] as bool,
    };
  }

  /// Pose (ou remplace) le défaut de plusieurs amis d'un coup — c'est ce que
  /// fait le bouton « Défauts » du sur-écran, pour tous les sélectionnés.
  ///
  /// ⚠️ L'invalidation appartient à l'ÉCRITURE : quiconque lit
  /// [friendShareDefaultsProvider] ensuite voit la nouvelle valeur.
  Future<void> setMany(Map<String, bool> saveableByFriend) async {
    final me = ref.read(currentUserIdProvider);
    if (me == null || saveableByFriend.isEmpty) return;
    await ref.read(supabaseProvider).from('friend_share_defaults').upsert([
      for (final e in saveableByFriend.entries)
        {
          'owner_id': me,
          'friend_id': e.key,
          'saveable': e.value,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
    ], onConflict: 'owner_id,friend_id');
    ref.invalidate(friendShareDefaultsProvider);
  }

  /// Retire le défaut d'un ami : il retombe sur mon défaut général.
  Future<void> clear(String friendId) async {
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;
    await ref
        .read(supabaseProvider)
        .from('friend_share_defaults')
        .delete()
        .eq('owner_id', me)
        .eq('friend_id', friendId);
    ref.invalidate(friendShareDefaultsProvider);
  }
}

final friendShareDefaultsRepositoryProvider = Provider(
  (ref) => FriendShareDefaultsRepository(ref),
);

/// Les défauts par ami, tels que le serveur les connaît. Vide = aucun.
final friendShareDefaultsProvider = FutureProvider<Map<String, bool>>((ref) {
  if (ref.watch(currentUserIdProvider) == null) return Future.value(const {});
  return ref.read(friendShareDefaultsRepositoryProvider).all();
});
