import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/content/content_face.dart';
import '../../core/content/content_media_cache.dart';
import '../../core/content/own_keys.dart';
import '../../core/crypto/chunked_seal.dart';
import '../../core/media/face_delivery.dart';
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
      .select(LibraryItem.select)
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

  /// Publie une **Card** dans ma bibliothèque de profil : dépôt des faces
  /// **chiffrées**, puis création de l'identité, du format et de la clé en une
  /// seule transaction serveur (`publish_to_library`).
  ///
  /// [back] null = publication à face unique — le cas d'une Vibe dont le verso
  /// a été passé à la prise. Une photo importée passe désormais par
  /// [publishAlbum] (2026-09-15).
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
  }) => _publish(
    kind: LibraryKind.card,
    cardType: type,
    media: [
      _Upload(front, isVideo: frontIsVideo),
      if (back != null) _Upload(back, isVideo: backIsVideo),
    ],
    caption: caption,
    isPublic: isPublic,
    shareable: shareable,
    saveable: saveable,
  );

  /// Publie un **album** : de 1 à 20 médias déjà préparés par l'éditeur
  /// (photos rendues, vidéos recompressées ≤ 60 s, couvertures extraites),
  /// tous scellés avec **la même clé**, puis la même transaction serveur.
  ///
  /// [onProgress] est appelé après chaque fichier déposé — un album de vingt
  /// vidéos, c'est une minute d'envoi ; l'écran doit pouvoir le dire.
  Future<String> publishAlbum(
    AlbumUpload album, {
    void Function(int done, int total)? onProgress,
  }) => _publish(
    // **La requalification** (Jay, 2026-09-17) : une vidéo publiée seule
    // n'est pas une publication ordinaire, c'est un Flow. Elle se décide
    // ici, sur le contenu réel, et pas dans un écran — un autre chemin de
    // publication ne pourrait pas l'oublier.
    kind: kindDuContenu(album.media),
    aspect: album.aspect,
    media: album.media,
    caption: album.caption,
    isPublic: album.isPublic,
    shareable: album.shareable,
    saveable: album.saveable,
    onProgress: onProgress,
  );

  Future<String> _publish({
    required LibraryKind kind,
    required List<_Upload> media,
    CardType cardType = CardType.standard,
    AlbumAspect? aspect,
    String? caption,
    required bool isPublic,
    required bool shareable,
    required bool saveable,
    void Function(int done, int total)? onProgress,
  }) async {
    assert(media.isNotEmpty && media.length <= 11);
    final me = _client.auth.currentUser!.id;
    final itemId = newUuid();

    // La MÊME clé chiffre tous les médias : AES-GCM tire un nonce aléatoire à
    // chaque appel, des fichiers distincts restent donc sûrs.
    final mediaKey = await ChunkedSeal.newKey();
    const sealedType = FileOptions(contentType: 'application/octet-stream');
    final temp = await getTemporaryDirectory();

    // Le nombre de fichiers à déposer : un par média, plus une couverture par
    // vidéo d'album.
    final total = media.length + media.where((m) => m.poster != null).length;
    var done = 0;

    Future<File> depose(
      File source,
      String path, {
      required bool isVideo,
    }) async {
      final sealed = File('${temp.path}/seal_${itemId}_$done');
      await FaceDelivery.seal(source, sealed, mediaKey, isVideo: isVideo);
      await _client.storage
          .from(_bucket)
          .uploadBinary(
            path,
            await sealed.readAsBytes(),
            fileOptions: sealedType,
          );
      done += 1;
      onProgress?.call(done, total);
      return sealed;
    }

    final rows = <Map<String, Object?>>[];
    final sealedFiles = <(int, File)>[];
    for (var slot = 0; slot < media.length; slot++) {
      final m = media[slot];
      final path = '$me/${itemId}_$slot.${m.isVideo ? 'mp4' : 'jpg'}';
      sealedFiles.add((slot, await depose(m.file, path, isVideo: m.isVideo)));
      String? posterPath;
      if (m.poster != null) {
        posterPath = '$me/${itemId}_${slot}_poster.jpg';
        // La couverture est rangée en cache sous sa place fictive : la
        // vignette de MON album s'affiche depuis l'appareil, comme ses photos.
        sealedFiles.add((
          ContentSlot.poster(slot),
          await depose(m.poster!, posterPath, isVideo: false),
        ));
      }
      rows.add({
        'path': path,
        'is_video': m.isVideo,
        'duration_ms': m.isVideo ? m.durationMs : null,
        'poster_path': posterPath,
        'width': m.width,
        'height': m.height,
      });
    }

    await _client.rpc(
      'publish_to_library',
      params: {
        'p_item_id': itemId,
        'p_kind': kind.dbValue,
        'p_card_type': cardType.dbValue,
        'p_media': rows,
        'p_caption': caption,
        'p_is_public': isPublic,
        'p_shareable': shareable,
        'p_saveable': saveable,
        'p_media_key': mediaKey,
        'p_aspect_w': aspect?.w,
        'p_aspect_h': aspect?.h,
      },
    );

    // Voir `stories_repository.publish` : la clé de MES contenus reste locale.
    await ref.read(ownKeyStoreProvider).put(itemId, mediaKey);

    // Copie locale immédiate : ma bibliothèque s'affiche depuis l'appareil, pas
    // depuis le réseau (consigne de Jay). On y range le scellé — une seule
    // règle vaut alors partout, tout fichier en cache est chiffré.
    final cache = ref.read(contentMediaCacheProvider);
    for (final (slot, sealed) in sealedFiles) {
      try {
        await cache.storeOwn(itemId, sealed, slot: slot);
        await sealed.delete();
      } catch (_) {}
    }

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

  Future<void> removeItem(String itemId) async {
    // La ligne `contents` est emportée par la suppression : c'est elle qui
    // porte l'identité. Le graphe et les vues la suivent — une publication
    // supprimée par son auteur disparaît vraiment, contrairement à une story
    // expirée dont le journal survit.
    await _client.from('contents').delete().eq('id', itemId);
    await ref.read(contentMediaCacheProvider).purge(itemId);
    // La clé locale de MON contenu part avec lui : sans contenu, elle ne
    // déchiffre plus rien et n'est qu'un secret orphelin de plus sur le disque.
    // Ajouté le 2026-08-31 — c'était le seul appelant qui manquait à
    // `OwnKeyStore.remove`, dont la documentation promettait un effacement.
    await ref.read(ownKeyStoreProvider).remove(itemId);
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
    // ⚠️ L'invalidation appartient à l'écriture (2026-08-25). Elle était faite
    // par l'écran appelant : un second appelant l'aurait oubliée, et lui seul
    // aurait affiché du périmé.
    ref.invalidate(myProfileProvider);
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

/// Un fichier à déposer : le média en clair (temporaire, produit par la
/// capture ou par l'éditeur), et pour une vidéo d'album sa couverture.
class _Upload {
  const _Upload(
    this.file, {
    required this.isVideo,
    this.durationMs,
    this.poster,
    this.width,
    this.height,
  });
  final File file;
  final bool isVideo;
  final int? durationMs;
  final File? poster;
  final int? width;
  final int? height;
}

/// Un média d'album prêt à partir, tel que l'éditeur le rend.
/// **La requalification, en une règle et un seul endroit** : une vidéo
/// publiée SEULE est un [LibraryKind.flow] ; tout le reste est une
/// publication ordinaire (Jay, 2026-09-17 — « comme Insta requalifie en Reel
/// les vidéos seules »).
///
/// Elle vit ici, sur le contenu réel, et pas dans un écran : un autre chemin
/// de publication (un partage, un import, demain le feed) ne peut pas
/// l'oublier. Et le serveur tient la même règle — un Flow à deux médias y est
/// refusé.
LibraryKind kindDuContenu(List<AlbumMediaUpload> media) =>
    media.length == 1 && media.first.isVideo
    ? LibraryKind.flow
    : LibraryKind.album;

class AlbumMediaUpload extends _Upload {
  const AlbumMediaUpload(
    super.file, {
    required super.isVideo,
    super.durationMs,
    super.poster,
    super.width,
    super.height,
  }) : assert(
         !isVideo || (durationMs != null && poster != null),
         "Une vidéo d'album porte sa durée et sa couverture",
       );
}

/// Ce que l'éditeur rend à la publication : les médias dans l'ordre, le ratio
/// commun, la légende et les droits.
class AlbumUpload {
  const AlbumUpload({
    required this.media,
    required this.aspect,
    this.caption,
    this.isPublic = false,
    this.shareable = false,
    this.saveable = false,
  }) : assert(media.length >= 1 && media.length <= 11);
  final List<AlbumMediaUpload> media;
  final AlbumAspect aspect;
  final String? caption;
  final bool isPublic;
  final bool shareable;
  final bool saveable;
}
