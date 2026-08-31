import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/media_open.dart';
import '../supabase_providers.dart';
import '../video/video_open_trace.dart';
import 'content_media_cache.dart';
import 'content_preloader.dart';
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

  /// Quand ce contenu cesse d'exister côté serveur. **Nul = permanent**
  /// (une publication) ; non nul pour une story.
  ///
  /// ## 🔴 Pourquoi ce champ existe — 2026-08-31
  ///
  /// `ContentMediaCache` accepte un `expiresAt` depuis toujours et **personne
  /// ne le passait**. Toutes les entrées étaient donc indexées comme
  /// permanentes, et la purge par expiration de `_enforceLimits` ne
  /// s'appliquait à rien : le cache ne se vidait que par son plafond de 150 Mo.
  /// Des stories mortes depuis des jours occupaient la place de contenus vivants.
  ///
  /// ⚠️ **Le champ est OBLIGATOIRE, sans valeur par défaut.** Un défaut à
  /// `null` aurait laissé chaque nouveau site d'appel retomber en silence sur
  /// « permanent » — c'est exactement ce qui vient de se produire pendant vingt
  /// jours. Ici, ajouter un écran force à répondre à la question.
  DateTime? expiresAt,
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
  final preloader = ref.watch(contentPreloaderProvider);
  final batch = spec.batchOwner == null
      ? null
      : ref.watch(libraryKeysProvider(spec.batchOwner!).future);

  final cacheId = '${spec.contentId}_${spec.front ? 'f' : 'b'}';
  // L'origine des temps est ICI, et pas à la création du lecteur : ce que
  // l'utilisateur attend inclut le téléchargement et l'aller-retour de clé.
  // Mesurer à partir du lecteur cacherait précisément ce qu'on cherche.
  final trace = spec.isVideo ? VideoOpenTrace.start(cacheId) : null;
  // Le natif dira « partiel » pour une face amorcée comme pour une vidéo vue à
  // moitié : il voit la même chose. Seul le Dart sait laquelle il a préparée.
  //
  // ⚠️ La question est posée SOUS FORME DE FONCTION, évaluée à l'ouverture du
  // lecteur. Y répondre ici — comme le faisait la v0.9.67 — c'était répondre
  // avant que `prime` n'ait fini d'amener le premier bloc, et ranger dans
  // « Partiel » un préchargement parfaitement réussi.
  trace?.isPrimed = () =>
      preloader.wasPrimed(spec.contentId, front: spec.front);

  // Préchargée ? Alors elle est déjà en main : une URL signée est un ticket
  // valable une heure, rien n'oblige à en redemander un. C'est le second
  // aller-retour que le préchargement retire du chemin visible.
  Future<String> signedUrl() async =>
      preloader.urlFor(spec.contentId, front: spec.front) ??
      await client.storage.from(spec.bucket).createSignedUrl(spec.path, 3600);

  // Ordre de recherche de la clé :
  //   1. MES propres contenus : la clé est sur l'appareil, elle y a été
  //      fabriquée. Rouvrir ma story ne demande donc RIEN au réseau.
  //   2. Le lot de la bibliothèque, quand on affiche une grille.
  //   3. Un appel unitaire au serveur.
  // Pour le contenu d'AUTRUI, seul le serveur décide — toujours, à chaque
  // ouverture. La garantie n'est pas touchée.
  Future<String> resolveKey() async {
    var key = spec.ownerId == me ? await ownKeys.get(spec.contentId) : null;
    key ??= batch == null ? null : (await batch)[spec.contentId];
    // Préchargée ? C'est ce qui retire l'aller-retour de clé du chemin visible
    // — ~110 ms mesurés le 2026-08-13. Possible depuis que `open_content_media`
    // n'enregistre plus la vue : obtenir la clé n'est plus « regarder ».
    key ??= preloader.keyFor(spec.contentId);
    key ??=
        await client.rpc(
              'open_content_media',
              params: {'p_content_id': spec.contentId},
            )
            as String;
    return key;
  }

  File? sealed;
  if (spec.ownerId == me) {
    sealed = await cache.tryOwn(spec.contentId, front: spec.front);
  }
  // Le classement de la mesure (complet / partiel / froid) n'est PAS fait ici :
  // le Dart ne peut pas le connaître. Le cache par blocs donne au fichier sa
  // taille définitive dès le premier bloc, si bien qu'« il existe » ne veut rien
  // dire. C'est le natif qui répond, à l'ouverture — voir [MediaAvailability].

  // ─── Une VIDÉO d'autrui ne se télécharge plus ──────────────────────────
  // Le lecteur natif ne réclame que les blocs qu'il traverse. Attendre le
  // fichier entier, c'était jusqu'à une minute sur un réseau lent pour 15 s de
  // vidéo — et c'est ce qui rendait un feed impossible.
  if (spec.isVideo && sealed == null) {
    // ⚠️ L'URL signée et la clé sont **indépendantes**. Les attendre l'une
    // après l'autre ajoutait un aller-retour complet à CHAQUE ouverture, en
    // cache comme à froid — sur une cible de 300 ms où un aller-retour mobile
    // en coûte 100 à 200. Elles partent donc ensemble.
    //
    // `.wait` plutôt que deux `await` successifs : il observe les DEUX futures.
    // Avec deux `await`, un échec de la seconde pendant l'attente de la
    // première remonterait en exception non observée, hors de toute pile
    // d'appel exploitable.
    // ⚠️ Menés en parallèle, ces deux coûts ne peuvent PAS être lus sur la
    // frise des jalons : les deux tomberaient au même instant, et « clé : 0 ms »
    // serait une conséquence de l'instrument, pas une mesure (contresens du
    // 2026-08-13 matin). Chacun est donc chronométré à part.
    final since = DateTime.now();
    int elapsed() => DateTime.now().difference(since).inMilliseconds;

    final urlFuture = signedUrl().then((value) {
      trace?.note('URL signée', elapsed());
      return value;
    });
    final keyFuture = resolveKey().then((value) {
      trace?.note('clé', elapsed());
      return value;
    });
    final cachePath = await cache.streamingPath(
      spec.contentId,
      front: spec.front,
      expiresAt: spec.expiresAt,
    );
    final (url, key) = await (urlFuture, keyFuture).wait;
    // Le jalon marque la fin des DEUX : c'est ce que l'utilisateur attend. Qui
    // des deux a duré se lit dans le détail ci-dessus.
    trace?.mark(VideoOpenStep.scelle);
    trace?.mark(VideoOpenStep.cle);
    return OpenedMedia.streaming(
      url: url,
      cachePath: cachePath,
      key: key,
      traceId: cacheId,
      // Un contenu scellé AVANT le format par blocs : le natif ne sait pas le
      // lire, on retombe alors sur l'ancien chemin — téléchargement complet
      // puis déchiffrement côté Dart.
      legacyFallback: () async {
        final file = await cache.others(
          spec.contentId,
          front: spec.front,
          signedUrl: signedUrl,
          expiresAt: spec.expiresAt,
        );
        final media = await MediaOpen.open(
          file,
          key,
          isVideo: true,
          cacheId: cacheId,
        );
        return media.clearFile!;
      },
    );
  }

  sealed ??= await cache.others(
    spec.contentId,
    front: spec.front,
    signedUrl: signedUrl,
    expiresAt: spec.expiresAt,
  );
  trace?.mark(VideoOpenStep.scelle);

  final key = await resolveKey();
  trace?.mark(VideoOpenStep.cle);

  final media = await MediaOpen.open(
    sealed,
    key,
    isVideo: spec.isVideo,
    cacheId: cacheId,
  );
  // L'éventuel fichier en clair d'un média hérité meurt avec l'écran.
  ref.onDispose(media.dispose);
  return media;
});
