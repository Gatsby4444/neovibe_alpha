import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/content/content_media_cache.dart';
import '../../core/content/own_keys.dart';
import '../../core/content/content_face.dart';
import '../../core/crypto/chunked_seal.dart';
import '../../core/diagnostics/app_log.dart';
import '../../core/location/anchor.dart';
import '../../core/models/card.dart';
import '../../core/models/library_item.dart';
import '../../core/models/profile.dart';
import '../../core/publish/publish_bridge.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/ids.dart';
import '../cards/native_media.dart';

/// Bibliothèque d'un utilisateur (la RLS applique les droits d'accès :
/// on reçoit une liste vide si l'accès est refusé).
///
/// Plus de jointure `cards(*)` : une publication n'est plus une Card de
/// chat, elle porte ses propres fichiers.
///
/// **MA bibliothèque a une copie sur l'appareil** (2026-09-20) : la liste
/// reçue du serveur est écrite dans un fichier ; sans réseau, c'est elle qui
/// sert — avec les faces déjà en cache, mes publications s'affichent en
/// mode avion. Jay : *« l'affichage de MES contenus ne doit jamais attendre
/// le réseau »*. La bibliothèque de quelqu'un d'autre, elle, vient du
/// serveur ou pas du tout.
final libraryItemsProvider = FutureProvider.family<List<LibraryItem>, String>((
  ref,
  ownerId,
) async {
  final me = ref.watch(currentUserIdProvider);
  final copie = ownerId == me ? await _copieLocale(ownerId) : null;
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('library_items')
        .select(LibraryItem.select)
        .eq('owner_id', ownerId)
        // Que des Vibes, dit positivement : une ligne d'un autre format
        // (aucune depuis la purge du 2026-09-21) n'arriverait pas ici.
        .eq('kind', kLibraryKindVibe)
        .order('created_at', ascending: false);
    if (copie != null) {
      unawaited(copie.writeAsString(jsonEncode(rows)).catchError((_) => copie));
    }
    return rows.map(LibraryItem.fromJson).toList();
  } catch (e) {
    if (copie == null || !await copie.exists()) rethrow;
    final rows = jsonDecode(await copie.readAsString()) as List;
    return [
      for (final r in rows) LibraryItem.fromJson(r as Map<String, dynamic>),
    ];
  }
});

Future<File> _copieLocale(String ownerId) async {
  final base = await getApplicationSupportDirectory();
  return File('${base.path}${Platform.pathSeparator}library_$ownerId.json');
}

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

  /// Publie une **Vibe** dans ma bibliothèque de profil — en la **déposant
  /// à la file native de publication** (`docs/file-de-publication.md`), qui
  /// scelle, envoie de façon reprenable et inscrit, avec ou sans l'app.
  ///
  /// Jay, 2026-09-21 : *« on fait la file native maintenant pour les
  /// Vibes »*. Avant, la Vibe gardait un envoi Dart simple, sous les yeux de
  /// l'utilisateur : fermer l'app ou perdre le réseau au milieu la perdait.
  /// Désormais elle apparaît tout de suite dans la grille avec son
  /// avancement (`PendingCell`), et finit quand même si l'app est fermée.
  ///
  /// Ce que l'app fait encore ici, à l'envoi :
  /// 1. copie les faces (déjà **finales** : rendues par l'éditeur ou telles
  ///    que capturées) dans le dossier de la publication — la source vit
  ///    sous `work/`, balayé au prochain démarrage ;
  /// 2. écrit la **couverture** que la grille montrera pendant l'envoi ;
  /// 3. tire la **clé**, la range dans `own_keys` (la Vibe sera lisible dès
  ///    qu'elle apparaît), calcule où chaque scellé ira dans le cache de mes
  ///    contenus ;
  /// 4. **dépose**, puis **libère** aussitôt : une Vibe n'a pas d'étape de
  ///    légende entre les deux, ses réglages sont connus à l'envoi.
  ///
  /// Rend l'identifiant de la publication **dès le dépôt** : l'inscription
  /// serveur est faite par le service ; son échec se lit dans la grille
  /// (point d'exclamation → Réessayer / Abandonner), pas ici.
  ///
  /// [back] null = Vibe à face unique (verso passé à la prise).
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
    ContentAnchor? anchor,
  }) async {
    final me = _client.auth.currentUser!.id;
    final bridge = PublishBridge.instance;
    final itemId = newUuid();
    final dirPath = await bridge.jobDir(itemId);
    if (dirPath == null) throw StateError('file de publication indisponible');
    final dir = Directory(dirPath);
    final cache = ref.read(contentMediaCacheProvider);

    // La MÊME clé chiffre les deux faces : AES-GCM tire un nonce aléatoire à
    // chaque appel, des fichiers distincts restent donc sûrs.
    final mediaKey = await ChunkedSeal.newKey();

    final faces = [
      (front, frontIsVideo),
      if (back != null) (back, backIsVideo),
    ];
    final media = <Map<String, Object?>>[];
    final ownCache = <String, String>{};
    String? cover;
    for (var slot = 0; slot < faces.length; slot++) {
      final (source, isVideo) = faces[slot];
      final ext = isVideo ? 'mp4' : 'jpg';
      final clear = (await source.copy('${dir.path}/face_$slot.$ext')).path;
      ownCache['$slot'] = await cache.ownPath(itemId, slot: slot);
      if (slot == 0) {
        final c = '${dir.path}/cover.jpg';
        if (isVideo) {
          final ok = await NativeMedia.videoThumbnail(
            source: clear,
            dest: c,
            width: 480,
            atMs: 0,
          );
          if (ok) cover = c;
        } else {
          cover = (await File(clear).copy(c)).path;
        }
      }
      media.add({
        'slot': slot,
        'isVideo': isVideo,
        // La capture ne mesure ni les dimensions ni la durée d'une face :
        // le serveur les accepte nulles (comme avant la file).
        'width': null,
        'height': null,
        'source': null,
        // Pas de transcodage : la face est finale, le service la scelle
        // telle quelle (index MP4 remis en tête avant).
        'transcode': null,
        'coverMs': 0,
        'maxDurationMs': 0,
        'durationMs': null,
        'file': {
          'contentSlot': slot,
          'clear': clear,
          'sealed': '$clear.seal',
          'storagePath': '$me/${itemId}_$slot.$ext',
          'isSealed': false,
          'uploadUrl': null,
          'uploaded': false,
        },
        'poster': null,
      });
    }

    // Voir `stories_repository.publish` : la clé de MES contenus reste locale.
    await ref.read(ownKeyStoreProvider).put(itemId, mediaKey);

    await bridge.enqueue({
      'id': itemId,
      'ownerId': me,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'cardType': type.dbValue,
      'mediaKey': mediaKey,
      'media': media,
      'ownCache': ownCache,
      'cover': cover,
      'phase': 'preparing',
      'error': null,
      'attempts': 0,
      'progress': 0.0,
    });
    final texte = caption?.trim();
    await bridge.release(
      itemId,
      caption: texte == null || texte.isEmpty ? null : texte,
      isPublic: isPublic,
      shareable: shareable,
      saveable: saveable,
      // Déjà gommée à 100 m ; le serveur la gomme encore avant d'écrire.
      anchorLat: anchor?.lat,
      anchorLng: anchor?.lng,
    );
    AppLog.instance.app(
      'Vibe déposée à la file — ${itemId.substring(0, 8)} · '
      '${media.length} face(s)',
    );
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
