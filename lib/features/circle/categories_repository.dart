import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

/// Catégorie de conversations créée par l'utilisateur (consigne Jay
/// 2026-07-12) : nom libre de 25 caractères max, une conversation peut
/// appartenir à plusieurs catégories.
class ConversationCategory {
  const ConversationCategory({required this.id, required this.name});
  final String id;
  final String name;

  factory ConversationCategory.fromJson(Map<String, dynamic> json) =>
      ConversationCategory(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

/// Mes catégories personnalisées, par ordre de création.
final myCategoriesProvider = FutureProvider<List<ConversationCategory>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('conversation_categories')
      .select()
      .order('created_at');
  return rows.map(ConversationCategory.fromJson).toList();
});

/// Appartenances : id de catégorie → ids de conversations.
final categoryMembersProvider = FutureProvider<Map<String, Set<String>>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return {};
  final rows = await ref
      .watch(supabaseProvider)
      .from('conversation_category_members')
      .select('category_id, conversation_id');
  final map = <String, Set<String>>{};
  for (final row in rows) {
    map
        .putIfAbsent(row['category_id'] as String, () => <String>{})
        .add(row['conversation_id'] as String);
  }
  return map;
});

class CategoriesRepository {
  CategoriesRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  Future<void> create(String name) async {
    final me = _client.auth.currentUser!.id;
    await _client.from('conversation_categories').insert({
      'owner_id': me,
      'name': name.trim(),
    });
  }

  Future<void> delete(String categoryId) =>
      _client.from('conversation_categories').delete().eq('id', categoryId);

  Future<void> setMembership(
    String categoryId,
    String conversationId,
    bool member,
  ) async {
    if (member) {
      await _client
          .from('conversation_category_members')
          .upsert(
            {'category_id': categoryId, 'conversation_id': conversationId},
            onConflict: 'category_id,conversation_id',
            ignoreDuplicates: true,
          );
    } else {
      await _client
          .from('conversation_category_members')
          .delete()
          .eq('category_id', categoryId)
          .eq('conversation_id', conversationId);
    }
  }
}

final categoriesRepositoryProvider = Provider(
  (ref) => CategoriesRepository(ref),
);
