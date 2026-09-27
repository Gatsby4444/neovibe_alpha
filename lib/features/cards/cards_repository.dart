import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/nv_api.dart';
import '../../core/crypto/chunked_seal.dart';
import '../../core/utils/ids.dart';
import '../../core/media/face_delivery.dart';
import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/session_providers.dart';
import '../conversations/conversations_repository.dart';
import 'card_media_cache.dart';
import '../../core/work_dir.dart';

/// Cards reçues (livraisons non détruites), temps réel.
final receivedDeliveriesProvider = StreamProvider<List<CardDelivery>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return ref
      .watch(nvDirectProvider)
      .lignes(
        'card_deliveries',
        cle: const ['id'],
        colonne: 'recipient_id',
        valeur: me,
        ordre: 'delivered_at',
        croissant: false,
      )
      .map(
        (rows) => rows
            .map(CardDelivery.fromJson)
            .where((d) => d.destroyedAt == null)
            .toList(),
      );
});

/// Ma livraison pour une card (état du container côté destinataire).
final myDeliveryProvider = FutureProvider.family<CardDelivery?, String>(
  (ref, cardId) => ref.watch(cardsRepositoryProvider).myDelivery(cardId),
);

/// Demandes de replay en attente sur une de MES cards (côté émetteur).
final pendingReplayForCardProvider =
    FutureProvider.family<List<CardDelivery>, String>((ref, cardId) async {
      final rows =
          await ref.watch(nvApiProvider).op('card_deliveries_pending_replay', {
                'card_id': cardId,
              })
              as List;
      return [
        for (final r in rows) CardDelivery.fromJson(r as Map<String, dynamic>),
      ];
    });

/// ⚠️ **Le chat en avait sa propre copie** (`_cardProvider` dans
/// `chat_screen.dart`), mot pour mot, jusqu'au 2026-08-25. Deux chemins vers la
/// même donnée, dont un que personne d'autre ne pouvait réutiliser — et deux
/// caches distincts pour la même card. Supprimée au checkup #52.
final cardByIdProvider = FutureProvider.family<CardModel?, String>((
  ref,
  id,
) async {
  final data =
      await ref.watch(nvApiProvider).op('card_get', {'id': id})
          as Map<String, dynamic>?;
  return data == null ? null : CardModel.fromJson(data);
});

class CardsRepository {
  CardsRepository(this.ref);
  final Ref ref;

  NvApi get _api => ref.read(nvApiProvider);
  NvFichiers get _fichiers => ref.read(nvFichiersProvider);
  String get _moi => ref.read(currentUserIdProvider)!;

  /// Crée une Card : upload recto/verso puis insertion.
  /// [back] null = Card à face unique (verso passé à la prise).
  /// [viewDurationSeconds] null = lecture illimitée ; [maxViews] null = vues
  /// illimitées. [imported] : au moins une face vient de la galerie.
  /// [frontIsVideo]/[backIsVideo] : faces vidéo (mp4) ;
  /// [scrubbable] : barre de lecture contrôlable par le destinataire.
  Future<CardModel> create({
    required File front,
    File? back,
    required CardType type,
    int? viewDurationSeconds,
    int? maxViews,
    bool saveable = false,
    bool imported = false,
    bool frontIsVideo = false,
    bool backIsVideo = false,
    bool scrubbable = false,
  }) async {
    final me = _moi;
    // 🔴 **UN IDENTIFIANT, PAS UN HORODATAGE — corrigé le 2026-08-31.**
    //
    // Les chemins de stockage se bâtissaient sur `millisecondsSinceEpoch`.
    // Deux Vibes créées dans la même milliseconde par le même compte se
    // seraient donc disputé le même chemin, et le second téléversement aurait
    // échoué — ou pire, écrasé le premier selon le mode d'envoi.
    //
    // ⚠️ Le reste du projet le fait déjà bien : stories et publications
    // nomment leurs fichiers d'après leur Content ID (`newUuid`). Ce chemin-ci
    // était le seul à supposer que le temps suffit à distinguer.
    final stamp = newUuid();
    final frontPath = '$me/${stamp}_front.${frontIsVideo ? 'mp4' : 'jpg'}';
    final backPath = back == null
        ? null
        : '$me/${stamp}_back.${backIsVideo ? 'mp4' : 'jpg'}';
    // ─── Chiffrement des faces (2026-08-10) ─────────────────────────────
    // La limite de vues est désormais une GARANTIE et non une convention : le
    // serveur ne rend la clé qu'en décomptant (`open_card_media`). Les octets
    // déposés ici sont donc inertes — les télécharger ne montre rien.
    //
    // La MÊME clé chiffre les deux faces : AES-GCM tire un nonce aléatoire à
    // chaque appel, deux fichiers distincts restent donc sûrs.
    final mediaKey = await ChunkedSeal.newKey();
    const sealedType = 'application/octet-stream';

    // Préparée pour la livraison puis scellée par blocs, en flux — un seul
    // chemin pour les trois écrans qui publient (voir `FaceDelivery`).
    final temp = await WorkDir.named('seal');
    final sealedFront = File('${temp.path}/seal_card_${stamp}_f');
    await FaceDelivery.seal(
      front,
      sealedFront,
      mediaKey,
      isVideo: frontIsVideo,
    );
    await _fichiers.deposer('cards', frontPath, sealedFront, type: sealedType);
    File? sealedBack;
    if (back != null) {
      sealedBack = File('${temp.path}/seal_card_${stamp}_b');
      await FaceDelivery.seal(back, sealedBack, mediaKey, isVideo: backIsVideo);
      await _fichiers.deposer('cards', backPath!, sealedBack, type: sealedType);
    }

    final row =
        await _api.op('card_create', {
              'owner_id': me,
              'card_type': type.dbValue,
              'front_path': frontPath,
              'back_path': backPath,
              'view_duration_seconds': viewDurationSeconds,
              'max_views': maxViews,
              'saveable': type.canBeSaveable && saveable,
              'imported': imported,
              'front_is_video': frontIsVideo,
              'back_is_video': backIsVideo,
              'scrubbable': scrubbable,
              'encrypted': true,
            })
            as Map<String, dynamic>;
    final card = CardModel.fromJson(row);

    // La clé part APRÈS l'insertion : elle référence la card. Si cet appel
    // échouait, la Vibe serait indéchiffrable — d'où l'absence de `catch`,
    // l'erreur doit remonter à l'écran d'envoi.
    await _api.op('set_card_media_key', {
      'p_card_id': card.id,
      'p_media_key': mediaKey,
    });

    // Copie locale immédiate de MES faces : plus jamais de téléchargement
    // serveur pour rouvrir mes propres cards (consigne Jay 2026-07-13).
    //
    // On y range le **scellé**, pas le clair. Une seule règle vaut alors
    // partout : tout fichier en cache d'une Vibe chiffrée est chiffré, quelle
    // que soit sa provenance. Sans cela il faudrait deviner, à l'affichage, si
    // le fichier vient du cache local (clair) ou du serveur (scellé).
    // Bénéfice annexe : mes propres contenus deviennent illisibles sur le
    // disque de l'appareil.
    final cache = ref.read(cardMediaCacheProvider);
    final quota = ref.read(ownCardsQuotaMbProvider);

    Future<void> keepSealed(File sealed, {required bool isFront}) async {
      await cache.storeOwnFace(
        card.id,
        sealed,
        front: isFront,
        isVideo: isFront ? frontIsVideo : backIsVideo,
        quotaMb: quota,
      );
      try {
        await sealed.delete();
      } catch (_) {}
    }

    await keepSealed(sealedFront, isFront: true);
    if (sealedBack != null) await keepSealed(sealedBack, isFront: false);
    return card;
  }

  /// Réclame la clé de déchiffrement d'une Vibe — **et consomme une vue** si
  /// l'appelant est un destinataire en conversation.
  ///
  /// Le décompte et la remise de la clé sont une seule transaction serveur
  /// (`open_card_media`) : c'est ce qui fait de la limite de vues une garantie
  /// et non une convention. Il n'y a plus de `markViewed` à appeler pour une
  /// Vibe chiffrée — ce serait une seconde vue.
  Future<String> openMedia(String cardId) async {
    final key = await _api.op('open_card_media', {'p_card_id': cardId});
    return key as String;
  }

  /// Envoie une Card à des destinataires : livraison + message par conversation.
  /// One of One : un seul destinataire, contrainte re-vérifiée côté serveur.
  Future<void> send(CardModel card, List<String> recipientIds) async {
    final me = _moi;
    if (card.type == CardType.oneOfOne && recipientIds.length > 1) {
      throw StateError('Une Vibe 1/1 ne peut avoir qu\'un destinataire');
    }
    for (final recipientId in recipientIds) {
      final convId =
          await _api.op('get_or_create_direct_conversation', {
                'peer': recipientId,
              })
              as String;
      final message =
          await _api.op('message_send', {
                'conversation_id': convId,
                'sender_id': me,
                'kind': 'card',
                'card_id': card.id,
              })
              as Map<String, dynamic>;
      await _api.op('card_delivery_create', {
        'card_id': card.id,
        'recipient_id': recipientId,
        'message_id': message['id'],
      });
    }
  }

  /// Envoie une Vibe **dans une conversation déjà connue**, DM ou groupe.
  ///
  /// ## ⚠️ Pourquoi cette méthode existe à côté de [send]
  ///
  /// [send] part d'une liste de personnes et ouvre une conversation DIRECTE
  /// avec chacune (`get_or_create_direct_conversation`). Envoyer ainsi dans un
  /// groupe créerait **N conversations à deux** au lieu d'un message dans le
  /// groupe — chaque membre recevrait la Vibe en privé, et personne ne la
  /// verrait dans le fil commun.
  ///
  /// L'écran de partage, lui, travaille avec des **conversations** : il sait
  /// déjà où poster. Lui faire redécouvrir la conversation à partir des
  /// membres serait refaire un chemin qu'il a déjà.
  ///
  /// ⚠️ **Une seule Card pour toute la conversation, autant de livraisons que
  /// de membres.** C'est ce qui fait qu'envoyer à dix personnes ne coûte qu'une
  /// montée de fichier.
  Future<void> sendToConversation(
    CardModel card,
    String conversationId,
    List<String> recipientIds,
  ) async {
    final me = _moi;
    if (card.type == CardType.oneOfOne && recipientIds.length > 1) {
      throw StateError("Une Vibe 1/1 ne peut avoir qu'un destinataire");
    }
    final message =
        await _api.op('message_send', {
              'conversation_id': conversationId,
              'sender_id': me,
              'kind': 'card',
              'card_id': card.id,
            })
            as Map<String, dynamic>;
    for (final recipientId in recipientIds) {
      await _api.op('card_delivery_create', {
        'card_id': card.id,
        'recipient_id': recipientId,
        'message_id': message['id'],
      });
    }
    noteConversationActivity(ref);
  }

  /// **Envoie une Vibe à quelqu'un qu'on a croisé** — pas encore un ami.
  ///
  /// Ce n'est pas un message : c'est une **demande d'ami qui porte une Vibe**,
  /// ouverte 24 h après un croisement mutuel. Il n'existe aucun canal de
  /// discussion vers un inconnu qu'on a quitté, et il ne doit pas en exister.
  ///
  /// ⚠️ **Toutes les vérifications sont côté serveur** — croisement constaté,
  /// pas déjà amis, pas bloqués, Vibe m'appartenant. L'app ne fait que
  /// demander : une barrière tenue par le client n'est pas une barrière
  /// (`RAPPELS.md` #93).
  Future<void> sendToCrossed(CardModel card, String userId) => _api.op(
    'request_connection_with_vibe',
    {'peer': userId, 'p_card_id': card.id},
  );

  /// Ma livraison pour une card donnée (état de visionnage).
  Future<CardDelivery?> myDelivery(String cardId) async {
    final row =
        await _api.op('card_delivery_mine', {'card_id': cardId})
            as Map<String, dynamic>?;
    return row == null ? null : CardDelivery.fromJson(row);
  }

  Future<void> markViewed(String deliveryId) =>
      _api.op('mark_card_viewed', {'delivery_id': deliveryId});

  /// Replay : demandé par le destinataire, accordé par l'émetteur (+1 vue).
  Future<void> requestReplay(String deliveryId) =>
      _api.op('request_replay', {'delivery_id': deliveryId});

  Future<void> grantReplay(String deliveryId) =>
      _api.op('grant_replay', {'delivery_id': deliveryId});

  // ─── Gérer une Vibe envoyée (2026-09-25) ───────────────────────────────
  //
  // Le serveur est seul juge (`delete_sent_vibe`, `update_sent_vibe` : son
  // auteur ; `hide_message` : un membre du chat). ⚠️ L'invalidation
  // appartient à l'ÉCRITURE : cacher un message n'émet aucun événement temps
  // réel (rien ne change dans `messages`), la lecture du chat est donc
  // relancée ici — sans quoi le container resterait affiché jusqu'au
  // prochain renouvellement du jeton.

  /// Supprime MA Vibe **pour tout le monde** : ses containers quittent tous
  /// les chats, ses octets partent au balai serveur.
  Future<void> deleteSent(CardModel card) async {
    await _api.op('delete_sent_vibe', {'p_card_id': card.id});
    ref.invalidate(cardByIdProvider(card.id));
    // Une même Vibe peut être partie dans plusieurs chats : tous relisent.
    ref.invalidate(messagesStreamProvider);
  }

  /// Modifie les règles de MA Vibe envoyée — mêmes bornes qu'à l'envoi,
  /// tenues par le serveur (Oneshot sans durée, 1/1 jamais sauvegardable).
  Future<void> updateSent(
    CardModel card, {
    required int? maxViews,
    required int? viewDurationSeconds,
    required bool scrubbable,
    required bool saveable,
  }) async {
    await _api.op('update_sent_vibe', {
      'p_card_id': card.id,
      'p_max_views': maxViews,
      'p_view_duration_seconds': viewDurationSeconds,
      'p_scrubbable': scrubbable,
      'p_saveable': saveable,
    });
    ref.invalidate(cardByIdProvider(card.id));
  }

  /// **Supprimer pour moi** : ce container disparaît de MON chat ; la Vibe
  /// reste pour les autres, et ailleurs.
  Future<void> hideMessage(String messageId, String conversationId) async {
    await _api.op('hide_message', {'p_message_id': messageId});
    ref.invalidate(messagesStreamProvider(conversationId));
  }

  /// Demandes de replay en attente sur MES cards (émetteur).
  Future<List<CardDelivery>> pendingReplayRequests() async {
    final rows = await _api.op('card_replay_requests_mine') as List;
    return [
      for (final r in rows) CardDelivery.fromJson(r as Map<String, dynamic>),
    ];
  }

  Future<String> imageUrl(String path) => _fichiers.lien('cards', path);

  /// Statistiques de profil (amis, posts, cards 7 jours) — RLS : soi + amis.
  Future<({int friends, int posts, int cardsWeek})?> profileStats(
    String userId,
  ) async {
    final rows = await _api.op('profile_stats', {'target': userId}) as List;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    return (
      friends: row['friends'] as int? ?? 0,
      posts: row['posts'] as int? ?? 0,
      cardsWeek: row['cards_week'] as int? ?? 0,
    );
  }
}

/// Stats de profil — null si non autorisé (ni soi ni une connexion).
final profileStatsProvider =
    FutureProvider.family<({int friends, int posts, int cardsWeek})?, String>(
      (ref, userId) => ref.watch(cardsRepositoryProvider).profileStats(userId),
    );

/// ⚠️ Les Enregistrements ne vivent plus ici. Depuis le 2026-08-11, une
/// sauvegarde est une **copie locale** (`core/content/saved_store.dart`) et
/// non une ligne serveur : la table `saved_cards` a disparu.
///
/// Motif : elle était en `ON DELETE CASCADE`. Si l'auteur supprimait sa Vibe,
/// tous ceux qui l'avaient enregistrée la perdaient — alors qu'« Enregistrer »
/// promet de garder.
///
/// Bénéfice d'architecture : c'était aussi la dernière branche « accès
/// illimité » de `can_view_card_file`, qui passe de trois chemins à **deux**
/// (propriétaire, livraison).

final cardsRepositoryProvider = Provider((ref) => CardsRepository(ref));
