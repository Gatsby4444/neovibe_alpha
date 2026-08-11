import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/media_open.dart';
import '../supabase_providers.dart';
import 'content_media_cache.dart';
import 'own_keys.dart';

/// Toutes les clés d'une bibliothèque, en **un** aller-retour.
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

/// Identifie une face à afficher, quel que soit son contexte de diffusion.
typedef ContentFace = ({
  /// Content ID.
  String contentId,
  String ownerId,

  /// `stories` ou `library` — le coffre de son contexte.
  String bucket,
  String path,
  bool front,
  bool isVideo,
  bool encrypted,

  /// Non nul : la clé est prise dans le **lot** de la bibliothèque de cet
  /// utilisateur, au lieu d'un appel par face. C'est ce qui rend une grille
  /// tenable. Nul pour un contenu isolé (visionneuse, aperçu dans un fil).
  String? batchOwner,
});

/// Une face **ouverte**, prête à l'affichage.
///
/// Le chemin est le même partout depuis la v0.9.46 : scellé (cache local
/// d'abord) → clé → ouverture. Ce qui change depuis le format par blocs
/// (2026-08-12) : une **photo** arrive en mémoire, une **vidéo** par une URL
/// locale servie bloc par bloc. Plus rien n'est écrit en clair sur le disque.
///
/// ⚠️ **Tout `ref.watch` est fait AVANT le premier `await`** — un `ref.watch`
/// placé après une suspension n'enregistre pas sa dépendance de façon fiable.
/// C'est la règle du 2026-08-02, et l'avoir enfreinte a coûté une panne le
/// 2026-08-11.
final contentFaceProvider = FutureProvider.family<OpenedMedia, ContentFace>((
  ref,
  spec,
) async {
  final client = ref.watch(supabaseProvider);
  final cache = ref.watch(contentMediaCacheProvider);
  final me = ref.watch(currentUserIdProvider);
  final ownKeys = ref.watch(ownKeyStoreProvider);
  final batch = spec.batchOwner == null
      ? null
      : ref.watch(libraryKeysProvider(spec.batchOwner!).future);

  File? sealed;
  if (spec.ownerId == me) {
    sealed = await cache.tryOwn(spec.contentId, front: spec.front);
  }
  sealed ??= await cache.others(
    spec.contentId,
    front: spec.front,
    signedUrl: () =>
        client.storage.from(spec.bucket).createSignedUrl(spec.path, 3600),
  );

  // Ordre de recherche de la clé :
  //   1. MES propres contenus : la clé est sur l'appareil, elle y a été
  //      fabriquée. Rouvrir ma story ne demande donc RIEN au réseau.
  //   2. Le lot de la bibliothèque, quand on affiche une grille.
  //   3. Un appel unitaire au serveur.
  // Pour le contenu d'AUTRUI, seul le serveur décide — toujours, à chaque
  // ouverture. La garantie n'est pas touchée.
  var key = spec.ownerId == me ? await ownKeys.get(spec.contentId) : null;
  key ??= batch == null ? null : (await batch)[spec.contentId];
  key ??=
      await client.rpc(
            'open_content_media',
            params: {'p_content_id': spec.contentId},
          )
          as String;

  final media = await MediaOpen.open(
    sealed,
    key,
    isVideo: spec.isVideo,
    cacheId: '${spec.contentId}_${spec.front ? 'f' : 'b'}',
  );
  // Le jeton du serveur local et l'éventuel fichier hérité meurent avec
  // l'écran.
  ref.onDispose(media.dispose);
  return media;
});
