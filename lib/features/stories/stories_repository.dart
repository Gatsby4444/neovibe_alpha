import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/crypto/chunked_seal.dart';
import '../../core/media/face_delivery.dart';
import '../../core/models/card.dart';
import '../../core/models/story.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/ids.dart';
import '../../core/clock.dart';
import '../../core/derived_list.dart';
import '../connections/connections_repository.dart';
import '../../core/content/content_media_cache.dart';
import '../../core/content/own_keys.dart';

/// Toutes les stories vivantes que j'ai le droit de voir.
///
/// C'est la RLS qui décide, pas le client : `stories_select_audience` appelle
/// `private.story_audience`, qui répond à **une seule question** — cette
/// personne est-elle dans l'audience de cette story ? Trois façons d'y entrer
/// (l'auteur, le cercle, un repartage reçu), une seule règle.
///
/// Plus de jointure `cards(*)` : une story n'est plus une Card, elle porte ses
/// propres fichiers.
final storiesSourceProvider = FutureProvider<List<Story>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('stories')
      .select(
        '*, contents(shareable, saveable), profiles!stories_owner_id_fkey(*)',
      )
      .gt('expires_at', DateTime.now().toUtc().toIso8601String())
      // Chronologique, comme la visionneuse les joue (consigne Jay
      // 2026-08-14). L'invariant est de toute façon garanti par le
      // constructeur de `StoryRing` : ce tri-ci ne fait qu'éviter que la
      // requête dise le contraire de ce que l'app affiche.
      .order('created_at', ascending: true);
  return rows.map(Story.fromJson).toList();
});

/// Regroupe les stories par auteur. L'auteur sans profil joint est écarté :
/// sans pseudo ni avatar, il n'y a rien à afficher.
///
/// **Deux ordres différents, à ne pas confondre** :
/// - les **anneaux** entre eux : le plus récemment actif d'abord (`latestAt`) ;
/// - les **stories d'un anneau** : de la plus ancienne à la plus récente,
///   garanti par le constructeur de [StoryRing].
List<StoryRing> _ring(List<Story> stories) {
  final byOwner = <String, List<Story>>{};
  for (final story in stories) {
    if (story.owner == null) continue;
    byOwner.putIfAbsent(story.ownerId, () => []).add(story);
  }
  final rings = byOwner.values
      .map((list) => StoryRing(owner: list.first.owner!, stories: list))
      .toList();
  rings.sort((a, b) => b.latestAt.compareTo(a.latestAt));
  return rings;
}

/// Bandeau du **Cercle** : mes stories et celles de mes amis.
/// Les stories encore valides **à cet instant**.
///
/// ⚠️ **Ajouté le 2026-08-25** (checkup `RAPPELS.md` #52). La requête filtre
/// déjà sur `expires_at` — mais c'est un **instantané** : une story qui atteint
/// ses 24 h pendant que l'écran est ouvert y restait jusqu'à ce qu'un événement
/// sans rapport invalide le cache. Exactement la « disparition buggée » signalée
/// par Jay sur les messages le 2026-07-13, à un autre endroit.
///
/// Le filtre serveur reste : il borne le VOLUME rapatrié, ce qui est bien le
/// travail de l'acquisition. Celui-ci décide de ce qui est AFFICHÉ.
final _liveStoriesProvider = Provider<AsyncValue<ValueList<Story>>>((ref) {
  final now = ref.watch(expiryClockProvider);
  // ⚠️ `whenData` PRÉSERVE les états `loading` et `error`. Les aplatir en liste
  // vide rendrait une panne indiscernable d'une absence de story — c'est
  // exactement ce qui a masqué le défaut du 2026-08-02.
  return ref
      .watch(storiesSourceProvider)
      .whenData(
        (toutes) => ValueList(
          toutes.where((s) => s.expiresAt.isAfter(now)).toList(growable: false),
        ),
      );
});

final friendStoriesProvider = Provider<AsyncValue<ValueList<StoryRing>>>((ref) {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const AsyncData(ValueList.empty());
  // ⚠️ **On observe les IDENTIFIANTS, pas les connexions** (2026-08-25). Lire
  // `fullConnectionsProvider` en entier faisait recalculer ce bandeau dès qu'un
  // ami changeait d'avatar — ou, pire, dès qu'une connexion *partielle*
  // bougeait, c'est-à-dire au passage d'un inconnu dans la rue.
  final friends = ref.watch(friendIdsProvider);
  return ref
      .watch(_liveStoriesProvider)
      .whenData(
        (stories) => ValueList(
          _ring(
            stories
                .where((s) => s.ownerId == me || friends.contains(s.ownerId))
                .toList(),
          ),
        ),
      );
});

/// Bandeau du **Ping** : les stories des personnes croisées qui ne sont PAS
/// mes amis. Le tri se fait ici et non côté serveur — la RLS a déjà écarté
/// tout ce que je n'ai pas le droit de voir, il ne reste qu'à séparer les
/// deux fils pour ne pas afficher deux fois les mêmes personnes.
final crossedStoriesProvider = Provider<AsyncValue<ValueList<StoryRing>>>((
  ref,
) {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const AsyncData(ValueList.empty());
  final friends = ref.watch(friendIdsProvider);
  return ref
      .watch(_liveStoriesProvider)
      .whenData(
        (stories) => ValueList(
          _ring(
            stories
                .where((s) => s.ownerId != me && !friends.contains(s.ownerId))
                .toList(),
          ),
        ),
      );
});

/// Spectateurs NOMMÉS d'une de mes stories (ceux que je peux situer dans mon
/// cercle). Les autres n'apparaissent que dans [storyViewerCountProvider].
final storyViewersProvider = FutureProvider.family<List<StoryViewer>, String>((
  ref,
  storyId,
) async {
  final rows = await ref
      .watch(supabaseProvider)
      .rpc('content_viewers', params: {'p_content_id': storyId});
  return (rows as List)
      .map((r) => StoryViewer.fromJson(r as Map<String, dynamic>))
      .toList();
});

/// Nombre TOTAL de personnes ayant vu, propagation comprise.
final storyViewerCountProvider = FutureProvider.family<int, String>((
  ref,
  storyId,
) async {
  final value = await ref
      .watch(supabaseProvider)
      .rpc('content_viewer_count', params: {'p_content_id': storyId});
  return (value as int?) ?? 0;
});

class StoriesRepository {
  StoriesRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  /// Publie une story : dépôt des faces **chiffrées** dans le bucket
  /// `stories`, puis création de l'identité, du format et de la clé en une
  /// seule transaction serveur (`publish_story`).
  ///
  /// L'identifiant est fabriqué ici parce qu'il nomme les fichiers **avant**
  /// leur téléversement — et il devient le Content ID du contenu.
  ///
  /// [shareable] : l'auteur autorise la propagation de cercle en cercle. Faux
  /// par défaut, c'est une décision reprise à chaque publication.
  Future<String> publish({
    required File front,
    File? back,
    required CardType type,
    bool frontIsVideo = false,
    bool backIsVideo = false,
    bool shareable = false,
    bool saveable = false,
  }) async {
    final me = _client.auth.currentUser!.id;
    final storyId = newUuid();
    final frontPath = '$me/${storyId}_front.${frontIsVideo ? 'mp4' : 'jpg'}';
    final backPath = back == null
        ? null
        : '$me/${storyId}_back.${backIsVideo ? 'mp4' : 'jpg'}';

    // La MÊME clé chiffre les deux faces : AES-GCM tire un nonce aléatoire à
    // chaque bloc, deux fichiers distincts restent donc sûrs.
    final mediaKey = await ChunkedSeal.newKey();
    const sealedType = FileOptions(contentType: 'application/octet-stream');

    // Préparée pour la livraison puis scellée par blocs, en flux — un seul
    // chemin pour les trois écrans qui publient (voir `FaceDelivery`).
    final temp = await getTemporaryDirectory();
    final sealedFront = File('${temp.path}/seal_${storyId}_f');
    await FaceDelivery.seal(
      front,
      sealedFront,
      mediaKey,
      isVideo: frontIsVideo,
    );
    await _client.storage
        .from('stories')
        .uploadBinary(
          frontPath,
          await sealedFront.readAsBytes(),
          fileOptions: sealedType,
        );
    File? sealedBack;
    if (back != null) {
      sealedBack = File('${temp.path}/seal_${storyId}_b');
      await FaceDelivery.seal(back, sealedBack, mediaKey, isVideo: backIsVideo);
      await _client.storage
          .from('stories')
          .uploadBinary(
            backPath!,
            await sealedBack.readAsBytes(),
            fileOptions: sealedType,
          );
    }

    await _client.rpc(
      'publish_story',
      params: {
        'p_story_id': storyId,
        'p_card_type': type.dbValue,
        'p_front_path': frontPath,
        'p_back_path': backPath,
        'p_front_is_video': frontIsVideo,
        'p_back_is_video': backIsVideo,
        'p_shareable': shareable,
        'p_media_key': mediaKey,
        'p_saveable': saveable,
      },
    );

    // La clé reste sur l'appareil : rouvrir MA story ne demandera plus le
    // réseau. Elle a été fabriquée ici, elle n'y ajoute aucun droit.
    await ref.read(ownKeyStoreProvider).put(storyId, mediaKey);

    // Copie locale immédiate : rouvrir MA propre story ne doit jamais
    // dépendre du réseau. On y range le scellé, comme pour les Cards — une
    // seule règle vaut alors partout, tout fichier en cache est chiffré.
    final cache = ref.read(contentMediaCacheProvider);
    Future<void> keep(File sealed, {required bool isFront}) async {
      try {
        await cache.storeOwn(storyId, sealed, front: isFront);
        await sealed.delete();
      } catch (_) {}
    }

    await keep(sealedFront, isFront: true);
    if (sealedBack != null) await keep(sealedBack, isFront: false);

    _invalidate();
    return storyId;
  }

  /// Réclame la clé de déchiffrement — **sans aucun décompte**. Une story n'a
  /// pas de limite de vues : c'est ce que la séparation des formats a rendu
  /// possible. L'appel enregistre la vue pour les statistiques de l'auteur.
  ///
  /// Lève si le contenu a été **révoqué** : c'est le point de contrôle unique.
  Future<String> openMedia(String storyId) async {
    final key = await _client.rpc(
      'open_content_media',
      params: {'p_content_id': storyId},
    );
    return key as String;
  }

  /// Repartage dans une conversation. **Aucun octet n'est copié** : on ajoute
  /// des chemins vers l'unique média (des arêtes au graphe de propagation).
  /// Le serveur refuse si la story n'est pas `shareable`.
  Future<int> shareToConversation(String storyId, String conversationId) async {
    final added = await _client.rpc(
      'share_content',
      params: {'p_content_id': storyId, 'p_conversation_id': conversationId},
    );
    return (added as int?) ?? 0;
  }

  Future<void> remove(String storyId) async {
    await _client.from('stories').delete().eq('id', storyId);
    // Les fichiers locaux n'ont plus de raison d'être : le serveur ne les
    // sert plus. L'identité et le graphe, eux, survivent côté serveur — c'est
    // ce qui permettra la traçabilité après coup.
    await ref.read(contentMediaCacheProvider).purge(storyId);
    _invalidate();
  }

  /// Bascule « stories publiques » : les croisés de moins de 24 h voient
  /// mes stories, en plus de mes amis.
  Future<void> setStoriesPublic(bool value) async {
    final me = _client.auth.currentUser!.id;
    await _client
        .from('profiles')
        .update({'stories_public': value})
        .eq('id', me);
    ref.invalidate(myProfileProvider);
  }

  Future<String> mediaUrl(String path) =>
      _client.storage.from('stories').createSignedUrl(path, 3600);

  void _invalidate() {
    ref.invalidate(storiesSourceProvider);
  }
}

final storiesRepositoryProvider = Provider(StoriesRepository.new);
