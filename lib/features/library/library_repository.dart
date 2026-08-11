import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/content/content_face.dart';
import '../../core/content/content_media_cache.dart';
import '../../core/content/own_keys.dart';
import '../../core/crypto/chunked_seal.dart';
import '../../core/models/card.dart';
import '../../core/models/library_item.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/ids.dart';

/// Bibliothèque d'un utilisateur (la RLS applique les droits d'accès :
/// on reçoit une liste vide si l'accès est refusé).
///
/// Plus de jointure `cards(*)` : une publication n'est plus une Card, elle
/// porte ses propres fichiers.
final libraryItemsProvider = FutureProvider.family<List<LibraryItem>, String>((
  ref,
  ownerId,
) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('library_items')
      .select('*, contents(shareable, saveable)')
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

  static const _bucket = 'library';

  /// Publie dans ma bibliothèque de profil : dépôt des faces **chiffrées**,
  /// puis création de l'identité, du format et de la clé en une seule
  /// transaction serveur (`publish_to_library`).
  ///
  /// [back] null = publication à face unique — le cas d'une photo importée
  /// comme celui d'une Vibe dont le verso a été passé à la prise. Les deux
  /// suivent désormais exactement le même chemin : c'est la même publication.
  ///
  /// [isPublic] : visible par toute personne accédant au profil par un moyen
  /// légitime. [shareable] : relayable de cercle en cercle.
  Future<String> publish({
    required File front,
    File? back,
    CardType type = CardType.standard,
    bool frontIsVideo = false,
    bool backIsVideo = false,
    String? caption,
    bool isPublic = false,
    bool shareable = false,
    bool saveable = false,
  }) async {
    final me = _client.auth.currentUser!.id;
    final itemId = newUuid();
    final frontPath = '$me/${itemId}_front.${frontIsVideo ? 'mp4' : 'jpg'}';
    final backPath = back == null
        ? null
        : '$me/${itemId}_back.${backIsVideo ? 'mp4' : 'jpg'}';

    // La MÊME clé chiffre les deux faces : AES-GCM tire un nonce aléatoire à
    // chaque appel, deux fichiers distincts restent donc sûrs.
    final mediaKey = await ChunkedSeal.newKey();
    const sealedType = FileOptions(contentType: 'application/octet-stream');

    // Scellé par blocs, en flux : voir `stories_repository.publish`.
    final temp = await getTemporaryDirectory();
    final sealedFront = File('${temp.path}/seal_${itemId}_f');
    await ChunkedSeal.sealFile(front, sealedFront, mediaKey);
    await _client.storage
        .from(_bucket)
        .uploadBinary(
          frontPath,
          await sealedFront.readAsBytes(),
          fileOptions: sealedType,
        );
    File? sealedBack;
    if (back != null) {
      sealedBack = File('${temp.path}/seal_${itemId}_b');
      await ChunkedSeal.sealFile(back, sealedBack, mediaKey);
      await _client.storage
          .from(_bucket)
          .uploadBinary(
            backPath!,
            await sealedBack.readAsBytes(),
            fileOptions: sealedType,
          );
    }

    await _client.rpc(
      'publish_to_library',
      params: {
        'p_item_id': itemId,
        'p_card_type': type.dbValue,
        'p_front_path': frontPath,
        'p_back_path': backPath,
        'p_front_is_video': frontIsVideo,
        'p_back_is_video': backIsVideo,
        'p_caption': caption,
        'p_is_public': isPublic,
        'p_shareable': shareable,
        'p_media_key': mediaKey,
        'p_saveable': saveable,
      },
    );

    // Voir `stories_repository.publish` : la clé de MES contenus reste locale.
    await ref.read(ownKeyStoreProvider).put(itemId, mediaKey);

    // Copie locale immédiate : ma bibliothèque s'affiche depuis l'appareil, pas
    // depuis le réseau (consigne de Jay). On y range le scellé — une seule
    // règle vaut alors partout, tout fichier en cache est chiffré.
    final cache = ref.read(contentMediaCacheProvider);
    Future<void> keep(File sealed, {required bool isFront}) async {
      try {
        await cache.storeOwn(itemId, sealed, front: isFront);
        await sealed.delete();
      } catch (_) {}
    }

    await keep(sealedFront, isFront: true);
    if (sealedBack != null) await keep(sealedBack, isFront: false);

    ref.invalidate(libraryItemsProvider(me));
    ref.invalidate(libraryKeysProvider(me));
    return itemId;
  }

  /// Réclame la clé d'une publication. Sans décompte : une publication n'a pas
  /// de limite de vues. Lève si le contenu a été **révoqué**.
  Future<String> openMedia(String itemId) async {
    final key = await _client.rpc(
      'open_content_media',
      params: {'p_content_id': itemId},
    );
    return key as String;
  }

  /// Repartage dans une conversation : aucun octet copié, seulement des
  /// chemins vers l'unique média.
  Future<int> shareToConversation(String itemId, String conversationId) async {
    final added = await _client.rpc(
      'share_content',
      params: {'p_content_id': itemId, 'p_conversation_id': conversationId},
    );
    return (added as int?) ?? 0;
  }

  Future<void> removeItem(String itemId) async {
    // La ligne `contents` est emportée par la suppression : c'est elle qui
    // porte l'identité. Le graphe et les vues la suivent — une publication
    // supprimée par son auteur disparaît vraiment, contrairement à une story
    // expirée dont le journal survit.
    await _client.from('contents').delete().eq('id', itemId);
    await ref.read(contentMediaCacheProvider).purge(itemId);
    final me = _client.auth.currentUser!.id;
    ref.invalidate(libraryItemsProvider(me));
    ref.invalidate(libraryKeysProvider(me));
  }

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
      _client.storage.from(_bucket).createSignedUrl(path, 3600);
}

final libraryRepositoryProvider = Provider((ref) => LibraryRepository(ref));
