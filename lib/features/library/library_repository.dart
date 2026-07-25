import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/library_item.dart';
import '../../core/models/profile.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../cards/card_media_cache.dart';

/// Bibliothèque d'un utilisateur (la RLS applique les droits d'accès :
/// on reçoit une liste vide si l'accès est refusé).
final libraryItemsProvider = FutureProvider.family<List<LibraryItem>, String>((
  ref,
  ownerId,
) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('library_items')
      .select('*, cards(*)')
      .eq('owner_id', ownerId)
      .order('created_at', ascending: false);
  return rows.map(LibraryItem.fromJson).toList();
});

/// Liste d'accès restreint à MA bibliothèque.
final libraryAccessProvider = FutureProvider<List<String>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('library_access')
      .select('grantee_id')
      .eq('owner_id', me);
  return rows.map((r) => r['grantee_id'] as String).toList();
});

class LibraryRepository {
  LibraryRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  /// [isPublic] : publication publique, visible par toute personne accédant
  /// au profil par un moyen légitime (option réglée à la publication).
  Future<void> addMedia(
    File file,
    String kind, {
    String? caption,
    bool isPublic = false,
  }) async {
    final me = _client.auth.currentUser!.id;
    final ext = kind == 'video' ? 'mp4' : 'jpg';
    final contentType = kind == 'video' ? 'video/mp4' : 'image/jpeg';
    final path = '$me/${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _client.storage
        .from('library')
        .upload(path, file, fileOptions: FileOptions(contentType: contentType));
    await _client.from('library_items').insert({
      'owner_id': me,
      'kind': kind,
      'media_path': path,
      'is_public': isPublic,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
    });
    // Copie locale immédiate : mes publications s'affichent depuis l'appareil,
    // pas depuis le réseau (les faces de cards le font déjà à la création).
    await ref
        .read(cardMediaCacheProvider)
        .storeOwnMedia(path, file, quotaMb: ref.read(ownCardsQuotaMbProvider));
  }

  Future<void> removeItem(String itemId) =>
      _client.from('library_items').delete().eq('id', itemId);

  Future<void> setVisibility(LibraryVisibility visibility) async {
    final me = _client.auth.currentUser!.id;
    await _client
        .from('profiles')
        .update({'library_visibility': visibility.name})
        .eq('id', me);
  }

  Future<void> grantAccess(String userId) async {
    final me = _client.auth.currentUser!.id;
    await _client.from('library_access').insert({
      'owner_id': me,
      'grantee_id': userId,
    });
  }

  Future<void> revokeAccess(String userId) async {
    final me = _client.auth.currentUser!.id;
    await _client
        .from('library_access')
        .delete()
        .eq('owner_id', me)
        .eq('grantee_id', userId);
  }

  Future<String> mediaUrl(String path) =>
      _client.storage.from('library').createSignedUrl(path, 3600);
}

final libraryRepositoryProvider = Provider((ref) => LibraryRepository(ref));
