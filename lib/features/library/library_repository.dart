import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/content/content_media_cache.dart';
import '../../core/crypto/media_seal.dart';
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
      .select('*, contents(shareable)')
      .eq('owner_id', ownerId)
      .order('created_at', ascending: false);
  return rows.map(LibraryItem.fromJson).toList();
});

/// Les clés de déchiffrement de toute une bibliothèque, en **un** aller-retour.
///
/// Sans ce lot, afficher une grille de 20 publications coûterait 20 appels
/// serveur — un par vignette. Le serveur ne renvoie que ce à quoi j'ai droit,
/// et rien de ce qui a été révoqué.
final libraryKeysProvider = FutureProvider.family<Map<String, String>, String>((
  ref,
  ownerId,
) async {
  final rows = await ref
      .watch(supabaseProvider)
      .rpc('library_media_keys', params: {'p_owner_id': ownerId});
  return {
    for (final row in rows as List)
      (row as Map<String, dynamic>)['content_id'] as String:
          row['media_key'] as String,
  };
});

/// Identifie une face de publication à afficher.
typedef PublicationFace = ({
  String itemId,
  String ownerId,
  String path,
  bool front,
  bool isVideo,
  bool encrypted,
});

/// Une face de publication **en clair**, prête à l'affichage.
///
/// Le chemin est le même que partout ailleurs depuis la v0.9.46 :
/// scellé (cache local d'abord) → clé → déchiffrement en fichier temporaire.
/// Le clair meurt avec le provider (`onDispose`) : il ne reste jamais sur le
/// disque une fois l'écran quitté.
///
/// La clé vient du **lot** `libraryKeysProvider` quand il est déjà chargé —
/// sans quoi une grille de 20 vignettes coûterait 20 appels serveur.
final publicationFaceProvider = FutureProvider.family<File, PublicationFace>((
  ref,
  spec,
) async {
  // ⚠️ TOUT `ref.watch` se fait AVANT le premier `await`.
  //
  // C'est la règle déjà écrite dans `stories_repository.dart` après la panne du
  // 2026-08-02 : un `ref.watch` placé après une suspension n'enregistre pas sa
  // dépendance de façon fiable. Je l'avais enfreinte ici en allant chercher le
  // lot de clés au milieu de la fonction — les vignettes ne se résolvaient
  // jamais et restaient grises indéfiniment.
  final repo = ref.watch(libraryRepositoryProvider);
  final cache = ref.watch(contentMediaCacheProvider);
  final me = ref.watch(currentUserIdProvider);
  final keysFuture = spec.encrypted
      ? ref.watch(libraryKeysProvider(spec.ownerId).future)
      : null;

  File? sealed;
  if (spec.ownerId == me) {
    sealed = await cache.tryOwn(spec.itemId, front: spec.front);
  }
  sealed ??= await cache.others(
    spec.itemId,
    front: spec.front,
    signedUrl: () => repo.mediaUrl(spec.path),
    // Une publication est permanente : pas d'expiration à indexer.
  );

  if (keysFuture == null) return sealed;

  final keys = await keysFuture;
  final key = keys[spec.itemId] ?? await repo.openMedia(spec.itemId);

  final temp = await getTemporaryDirectory();
  final target = File(
    '${temp.path}/pub_clear_${spec.itemId}_${spec.front ? 'f' : 'b'}'
    '${spec.isVideo ? '.mp4' : '.jpg'}',
  );
  final clear = await MediaSeal.unsealToFile(sealed, key, target);
  ref.onDispose(() {
    try {
      clear.deleteSync();
    } catch (_) {}
  });
  return clear;
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
  }) async {
    final me = _client.auth.currentUser!.id;
    final itemId = newUuid();
    final frontPath = '$me/${itemId}_front.${frontIsVideo ? 'mp4' : 'jpg'}';
    final backPath = back == null
        ? null
        : '$me/${itemId}_back.${backIsVideo ? 'mp4' : 'jpg'}';

    // La MÊME clé chiffre les deux faces : AES-GCM tire un nonce aléatoire à
    // chaque appel, deux fichiers distincts restent donc sûrs.
    final mediaKey = await MediaSeal.newKey();
    const sealedType = FileOptions(contentType: 'application/octet-stream');

    final sealedFront = await MediaSeal.sealFile(front, mediaKey);
    await _client.storage
        .from(_bucket)
        .uploadBinary(frontPath, sealedFront, fileOptions: sealedType);
    final sealedBack = back == null
        ? null
        : await MediaSeal.sealFile(back, mediaKey);
    if (sealedBack != null) {
      await _client.storage
          .from(_bucket)
          .uploadBinary(backPath!, sealedBack, fileOptions: sealedType);
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
      },
    );

    // Copie locale immédiate : ma bibliothèque s'affiche depuis l'appareil, pas
    // depuis le réseau (consigne de Jay). On y range le scellé — une seule
    // règle vaut alors partout, tout fichier en cache est chiffré.
    final cache = ref.read(contentMediaCacheProvider);
    final temp = await getTemporaryDirectory();
    Future<void> keep(List<int> sealed, {required bool isFront}) async {
      try {
        final file = File(
          '${temp.path}/pub_seal_${itemId}_${isFront ? 'f' : 'b'}',
        );
        await file.writeAsBytes(sealed, flush: true);
        await cache.storeOwn(itemId, file, front: isFront);
        await file.delete();
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
