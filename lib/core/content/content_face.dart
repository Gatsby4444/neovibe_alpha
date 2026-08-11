import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/media_seal.dart';
import '../supabase_providers.dart';
import 'content_media_cache.dart';

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

/// Une face **en clair**, prête à l'affichage — pour les stories comme pour
/// les publications.
///
/// Le chemin est le même partout depuis la v0.9.46 : scellé (cache local
/// d'abord) → clé → déchiffrement en fichier temporaire. Le clair meurt avec
/// le provider (`onDispose`) : il ne reste jamais sur le disque une fois
/// l'écran quitté.
///
/// ⚠️ **Tout `ref.watch` est fait AVANT le premier `await`** — un `ref.watch`
/// placé après une suspension n'enregistre pas sa dépendance de façon fiable.
/// C'est la règle du 2026-08-02, et l'avoir enfreinte a coûté une panne le
/// 2026-08-11.
final contentFaceProvider = FutureProvider.family<File, ContentFace>((
  ref,
  spec,
) async {
  final client = ref.watch(supabaseProvider);
  final cache = ref.watch(contentMediaCacheProvider);
  final me = ref.watch(currentUserIdProvider);
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

  if (!spec.encrypted) return sealed;

  // La clé vient du lot quand il y en a un ; sinon d'un appel unitaire. Dans
  // les deux cas c'est le serveur qui décide, et un contenu révoqué n'en
  // obtient aucune.
  final key =
      (batch == null ? null : (await batch)[spec.contentId]) ??
      await client.rpc(
            'open_content_media',
            params: {'p_content_id': spec.contentId},
          )
          as String;

  final temp = await getTemporaryDirectory();
  final target = File(
    '${temp.path}/clear_${spec.contentId}_${spec.front ? 'f' : 'b'}'
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
