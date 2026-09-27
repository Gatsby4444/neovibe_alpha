import 'package:supabase_flutter/supabase_flutter.dart';

/// Un geste direct sur les tables, sous un nom d'opération.
typedef GesteSupabase =
    Future<dynamic> Function(SupabaseClient c, Map<String, dynamic> a);

/// Le `select` d'une publication lue avec ce qu'elle permet et ses médias
/// (bibliothèque, fil, carte) : tout ce que `LibraryItem.fromJson` lit — un
/// seul endroit à tenir quand une colonne change. (Côté Rust, la même forme
/// est `vibes::publication::publication_complete`.)
const selectPublication = '*, contents(shareable, saveable), library_media(*)';

/// Les profils joints à une recommandation.
const _selectRecommandation =
    '*, '
    'requester:profiles!recommendations_requester_id_fkey(*), '
    'intermediary:profiles!recommendations_intermediary_id_fkey(*), '
    'target:profiles!recommendations_target_id_fkey(*)';

String _moi(SupabaseClient c) => c.auth.currentUser!.id;

/// **Les gestes directs de l'app, côté Supabase** — ce que les dépôts
/// écrivaient eux-mêmes avec `.from(…)` jusqu'au 2026-09-27, rangé ici sous
/// le NOM de l'opération qui fait la même chose sur le serveur Rust
/// (`server/crates/nv-app`). Même requête, même réponse : seul l'endroit a
/// changé.
///
/// Les droits restent ceux de la base (RLS) : un geste ne vérifie rien de
/// plus que ce que la requête faisait déjà.
final Map<String, GesteSupabase> gestesSupabase = {
  // ─── Comptes ─────────────────────────────────────────────────────────
  'profiles_get': (c, a) =>
      c.from('profiles').select().eq('id', a['p_id'] as String).maybeSingle(),
  'profiles_list': (c, a) => c
      .from('profiles')
      .select()
      .inFilter('id', List<String>.from(a['p_ids'] as List)),
  'profile_create': (c, a) => c.from('profiles').insert(a),
  'profile_update': (c, a) => c.from('profiles').update(a).eq('id', _moi(c)),
  'dev_report_insert': (c, a) => c.from('dev_reports').insert(a),

  // ─── Relations ───────────────────────────────────────────────────────
  'device_key_upsert': (c, a) => c.from('device_keys').upsert(a),
  'key_book_list': (c, a) => c.from('key_book').select(),
  'connection_delete': (c, a) =>
      c.from('connections').delete().eq('id', a['id'] as String),
  'connection_requests_history': (c, a) => c
      .from('connection_requests')
      .select()
      .order('created_at', ascending: false)
      .limit(50),
  'recommendations_list': (c, a) {
    final base = c.from('recommendations').select(_selectRecommandation);
    final me = _moi(c);
    final filtre = switch (a['p_role']) {
      'requester' => base.eq('requester_id', me),
      'intermediary' =>
        base.eq('intermediary_id', me).eq('status', 'requested'),
      _ => base.eq('target_id', me).eq('status', 'forwarded'),
    };
    return filtre.order('created_at', ascending: false);
  },
  'recommendation_create': (c, a) => c.from('recommendations').insert(a),
  'blocks_list': (c, a) => c
      .from('blocks')
      .select('blocked_id, profiles!blocks_blocked_id_fkey(*)')
      .eq('blocker_id', _moi(c))
      .order('created_at', ascending: false),
  'waves_list': (c, a) => c
      .from('waves')
      .select()
      .eq('user_id', _moi(c))
      .lte(
        'notify_after',
        a['p_before'] as String? ?? DateTime.now().toUtc().toIso8601String(),
      )
      .order('detected_at', ascending: false)
      .limit(50),
  'wave_insert': (c, a) => c.from('waves').insert(a),

  // ─── Conversations ───────────────────────────────────────────────────
  'conversations_list': (c, a) => c
      .from('conversations')
      .select('*, members:conversation_members(profiles(*))')
      .order('created_at', ascending: false),
  'conversation_get': (c, a) => c
      .from('conversations')
      .select('*, members:conversation_members(profiles(*))')
      .eq('id', a['id'] as String)
      .single(),
  'conversation_update_title': (c, a) => c
      .from('conversations')
      .update({'title': a['title']})
      .eq('id', a['id'] as String),
  'conversation_member_add': (c, a) => c.from('conversation_members').insert(a),
  'conversation_member_remove': (c, a) => c
      .from('conversation_members')
      .delete()
      .eq('conversation_id', a['conversation_id'] as String)
      .eq('user_id', a['user_id'] as String),
  'message_send': (c, a) => c.from('messages').insert(a).select().single(),
  'message_last': (c, a) => c
      .from('messages')
      .select()
      .eq('conversation_id', a['conversation_id'] as String)
      .order('created_at', ascending: false)
      .limit(1)
      .maybeSingle(),
  'message_reads_mark': (c, a) => c
      .from('message_reads')
      .upsert(
        [
          for (final id in a['message_ids'] as List)
            {'message_id': id, 'user_id': _moi(c)},
        ],
        onConflict: 'message_id,user_id',
        ignoreDuplicates: true,
      ),
  'conversation_participation_list': (c, a) =>
      c.from('conversation_participation').select('conversation_id, last_at'),
  'categories_list': (c, a) =>
      c.from('conversation_categories').select().order('created_at'),
  'category_create': (c, a) => c.from('conversation_categories').insert(a),
  'category_delete': (c, a) =>
      c.from('conversation_categories').delete().eq('id', a['id'] as String),
  'category_members_list': (c, a) => c
      .from('conversation_category_members')
      .select('category_id, conversation_id'),
  'category_member_add': (c, a) => c
      .from('conversation_category_members')
      .upsert(
        a,
        onConflict: 'category_id,conversation_id',
        ignoreDuplicates: true,
      ),
  'category_member_remove': (c, a) => c
      .from('conversation_category_members')
      .delete()
      .eq('category_id', a['category_id'] as String)
      .eq('conversation_id', a['conversation_id'] as String),

  // ─── Vibes et contenus ───────────────────────────────────────────────
  'card_get': (c, a) =>
      c.from('cards').select().eq('id', a['id'] as String).maybeSingle(),
  'card_create': (c, a) => c.from('cards').insert(a).select().single(),
  'card_delivery_create': (c, a) => c.from('card_deliveries').insert(a),
  'card_deliveries_pending_replay': (c, a) => c
      .from('card_deliveries')
      .select()
      .eq('card_id', a['card_id'] as String)
      .not('replay_requested_at', 'is', null)
      .filter('replay_granted_at', 'is', null),
  'card_replay_requests_mine': (c, a) => c
      .from('card_deliveries')
      .select('*, cards!inner(*)')
      .eq('cards.owner_id', _moi(c))
      .not('replay_requested_at', 'is', null)
      .filter('replay_granted_at', 'is', null),
  'card_delivery_mine': (c, a) => c
      .from('card_deliveries')
      .select()
      .eq('card_id', a['card_id'] as String)
      .eq('recipient_id', _moi(c))
      .maybeSingle(),
  'friend_share_defaults_list': (c, a) =>
      c.from('friend_share_defaults').select('friend_id, saveable'),
  'friend_share_defaults_upsert': (c, a) => c
      .from('friend_share_defaults')
      .upsert(a['rows'] as List, onConflict: 'owner_id,friend_id'),
  'friend_share_default_delete': (c, a) => c
      .from('friend_share_defaults')
      .delete()
      .eq('owner_id', _moi(c))
      .eq('friend_id', a['friend_id'] as String),
  'content_flags': (c, a) => c
      .from('contents')
      .select('context, shareable, saveable')
      .eq('id', a['id'] as String)
      .maybeSingle(),
  'content_delete': (c, a) =>
      c.from('contents').delete().eq('id', a['id'] as String),
  'capture_place_record': (c, a) => c.from('capture_places').upsert(a),
  'capture_place_get': (c, a) => c
      .from('capture_places')
      .select()
      .eq('object_id', a['object_id'] as String)
      .maybeSingle(),
  'library_vibes_list': (c, a) => c
      .from('library_vibes')
      .select()
      .eq('conversation_id', a['conversation_id'] as String)
      .order('reveal_at', ascending: false),
  'library_access_list': (c, a) =>
      c.from('library_access').select('grantee_id').eq('owner_id', _moi(c)),
  'library_access_grant': (c, a) => c.from('library_access').insert({
    'owner_id': _moi(c),
    'grantee_id': a['grantee_id'],
  }),
  'library_access_revoke': (c, a) => c
      .from('library_access')
      .delete()
      .eq('owner_id', _moi(c))
      .eq('grantee_id', a['grantee_id'] as String),
  'library_item_get': (c, a) => c
      .from('library_items')
      .select('*, library_media(*)')
      .eq('id', a['id'] as String)
      .maybeSingle(),
  'library_items_of': (c, a) => c
      .from('library_items')
      .select(selectPublication)
      .eq('owner_id', a['owner_id'] as String)
      .eq('kind', 'card')
      .order('created_at', ascending: false),
  'story_get': (c, a) => c
      .from('stories')
      .select('*, profiles!stories_owner_id_fkey(*)')
      .eq('id', a['id'] as String)
      .maybeSingle(),
  'stories_list': (c, a) => c
      .from('stories')
      .select(
        '*, contents(shareable, saveable), profiles!stories_owner_id_fkey(*)',
      )
      .gt('expires_at', DateTime.now().toUtc().toIso8601String())
      .order('created_at', ascending: true),

  // ─── Soirées ─────────────────────────────────────────────────────────
  'event_rules_map': (c, a) => c
      .from('event_rules')
      .select('nearby_radius_m, nearby_radius_max_m, big_event_min_present')
      .single(),
  'event_presence_mine': (c, a) => c
      .from('event_presences')
      .select('id')
      .eq('event_id', a['event_id'] as String)
      .eq('user_id', _moi(c))
      .limit(1),
  'event_challenges_list': (c, a) => c
      .from('event_challenges')
      .select('id, event_id, author_id, text, created_at')
      .eq('event_id', a['event_id'] as String)
      .order('created_at', ascending: false),
  'meeting_delete': (c, a) =>
      c.from('meetings').delete().eq('id', a['id'] as String),

  // ─── Carte ───────────────────────────────────────────────────────────
  'location_sharing_mine': (c, a) => c
      .from('location_sharing')
      .select('sharing')
      .eq('user_id', _moi(c))
      .maybeSingle(),
  'location_hidden_list': (c, a) => c
      .from('location_hidden_from')
      .select('friend_id')
      .eq('owner_id', _moi(c)),
  'map_rules_walking': (c, a) =>
      c.from('map_rules').select('walking_route_enabled').single(),

  // ─── Modération ──────────────────────────────────────────────────────
  'content_report_create': (c, a) => c.from('content_reports').insert(a),
  'profile_report_create': (c, a) => c.from('profile_reports').insert(a),
};
