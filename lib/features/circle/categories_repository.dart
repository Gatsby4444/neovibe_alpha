import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/nv_api.dart';
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
  final rows = await ref.watch(nvApiProvider).op('categories_list') as List;
  return [
    for (final r in rows)
      ConversationCategory.fromJson(r as Map<String, dynamic>),
  ];
});

/// Appartenances : id de catégorie → ids de conversations.
final categoryMembersProvider = FutureProvider<Map<String, Set<String>>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return {};
  final rows =
      (await ref.watch(nvApiProvider).op('category_members_list') as List)
          .cast<Map<String, dynamic>>();
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

  NvApi get _api => ref.read(nvApiProvider);

  Future<void> create(String name) async {
    final me = ref.read(currentUserIdProvider)!;
    await _api.op('category_create', {'owner_id': me, 'name': name.trim()});
  }

  Future<void> delete(String categoryId) =>
      _api.op('category_delete', {'id': categoryId});

  Future<void> setMembership(
    String categoryId,
    String conversationId,
    bool member,
  ) async {
    if (member) {
      await _api.op('category_member_add', {
        'category_id': categoryId,
        'conversation_id': conversationId,
      });
    } else {
      await _api.op('category_member_remove', {
        'category_id': categoryId,
        'conversation_id': conversationId,
      });
    }
  }
}

final categoriesRepositoryProvider = Provider(
  (ref) => CategoriesRepository(ref),
);
