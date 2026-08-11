import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:path_provider/path_provider.dart';

import '../../core/crypto/media_seal.dart';
import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import 'card_media_cache.dart';

/// Cards reçues (livraisons non détruites), temps réel.
final receivedDeliveriesProvider = StreamProvider<List<CardDelivery>>((ref) {
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('card_deliveries')
      .stream(primaryKey: ['id'])
      .eq('recipient_id', me)
      .order('delivered_at', ascending: false)
      .map(
        (rows) => rows
            .map(CardDelivery.fromJson)
            .where((d) => d.destroyedAt == null)
            .toList(),
      );
});

/// Demandes de replay en attente sur une de MES cards (côté émetteur).
final pendingReplayForCardProvider =
    FutureProvider.family<List<CardDelivery>, String>((ref, cardId) async {
      final rows = await ref
          .watch(supabaseProvider)
          .from('card_deliveries')
          .select()
          .eq('card_id', cardId)
          .not('replay_requested_at', 'is', null)
          .filter('replay_granted_at', 'is', null);
      return rows.map(CardDelivery.fromJson).toList();
    });

final cardByIdProvider = FutureProvider.family<CardModel?, String>((
  ref,
  id,
) async {
  final data = await ref
      .watch(supabaseProvider)
      .from('cards')
      .select()
      .eq('id', id)
      .maybeSingle();
  return data == null ? null : CardModel.fromJson(data);
});

class CardsRepository {
  CardsRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

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
    final me = _client.auth.currentUser!.id;
    final stamp = DateTime.now().millisecondsSinceEpoch;
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
    final mediaKey = await MediaSeal.newKey();
    const sealedType = FileOptions(contentType: 'application/octet-stream');

    await _client.storage
        .from('cards')
        .uploadBinary(
          frontPath,
          await MediaSeal.sealFile(front, mediaKey),
          fileOptions: sealedType,
        );
    if (back != null) {
      await _client.storage
          .from('cards')
          .uploadBinary(
            backPath!,
            await MediaSeal.sealFile(back, mediaKey),
            fileOptions: sealedType,
          );
    }

    final row = await _client
        .from('cards')
        .insert({
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
        .select()
        .single();
    final card = CardModel.fromJson(row);

    // La clé part APRÈS l'insertion : elle référence la card. Si cet appel
    // échouait, la Vibe serait indéchiffrable — d'où l'absence de `catch`,
    // l'erreur doit remonter à l'écran d'envoi.
    await _client.rpc(
      'set_card_media_key',
      params: {'p_card_id': card.id, 'p_media_key': mediaKey},
    );

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
    final temp = await getTemporaryDirectory();

    Future<void> keepSealed(File source, {required bool isFront}) async {
      final sealed = File(
        '${temp.path}/seal_${card.id}_${isFront ? 'f' : 'b'}',
      );
      await sealed.writeAsBytes(
        await MediaSeal.sealFile(source, mediaKey),
        flush: true,
      );
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

    await keepSealed(front, isFront: true);
    if (back != null) await keepSealed(back, isFront: false);
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
    final key = await _client.rpc(
      'open_card_media',
      params: {'p_card_id': cardId},
    );
    return key as String;
  }

  /// Envoie une Card à des destinataires : livraison + message par conversation.
  /// One of One : un seul destinataire, contrainte re-vérifiée côté serveur.
  Future<void> send(CardModel card, List<String> recipientIds) async {
    final me = _client.auth.currentUser!.id;
    if (card.type == CardType.oneOfOne && recipientIds.length > 1) {
      throw StateError('Une Vibe 1/1 ne peut avoir qu\'un destinataire');
    }
    for (final recipientId in recipientIds) {
      final convId =
          await _client.rpc(
                'get_or_create_direct_conversation',
                params: {'peer': recipientId},
              )
              as String;
      final message = await _client
          .from('messages')
          .insert({
            'conversation_id': convId,
            'sender_id': me,
            'kind': 'card',
            'card_id': card.id,
          })
          .select()
          .single();
      await _client.from('card_deliveries').insert({
        'card_id': card.id,
        'recipient_id': recipientId,
        'message_id': message['id'],
      });
    }
  }

  /// Envoie une Card dans un groupe : un message + livraison à chaque membre.
  Future<void> sendToGroup(
    CardModel card,
    String conversationId,
    List<String> memberIds,
  ) async {
    final me = _client.auth.currentUser!.id;
    final message = await _client
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': me,
          'kind': 'card',
          'card_id': card.id,
        })
        .select()
        .single();
    for (final memberId in memberIds.where((id) => id != me)) {
      await _client.from('card_deliveries').insert({
        'card_id': card.id,
        'recipient_id': memberId,
        'message_id': message['id'],
      });
    }
  }

  /// Ma livraison pour une card donnée (état de visionnage).
  Future<CardDelivery?> myDelivery(String cardId) async {
    final me = _client.auth.currentUser!.id;
    final row = await _client
        .from('card_deliveries')
        .select()
        .eq('card_id', cardId)
        .eq('recipient_id', me)
        .maybeSingle();
    return row == null ? null : CardDelivery.fromJson(row);
  }

  Future<void> markViewed(String deliveryId) =>
      _client.rpc('mark_card_viewed', params: {'delivery_id': deliveryId});

  /// Replay : demandé par le destinataire, accordé par l'émetteur (+1 vue).
  Future<void> requestReplay(String deliveryId) =>
      _client.rpc('request_replay', params: {'delivery_id': deliveryId});

  Future<void> grantReplay(String deliveryId) =>
      _client.rpc('grant_replay', params: {'delivery_id': deliveryId});

  /// Demandes de replay en attente sur MES cards (émetteur).
  Future<List<CardDelivery>> pendingReplayRequests() async {
    final me = _client.auth.currentUser!.id;
    final rows = await _client
        .from('card_deliveries')
        .select('*, cards!inner(*)')
        .eq('cards.owner_id', me)
        .not('replay_requested_at', 'is', null)
        .filter('replay_granted_at', 'is', null);
    return rows.map(CardDelivery.fromJson).toList();
  }

  Future<String> imageUrl(String path) =>
      _client.storage.from('cards').createSignedUrl(path, 3600);

  /// Enregistre une card dans MES Enregistrements (bibliothèque privée).
  Future<void> saveCard(String cardId) async {
    final me = _client.auth.currentUser!.id;
    await _client
        .from('saved_cards')
        .upsert(
          {'owner_id': me, 'card_id': cardId},
          onConflict: 'owner_id,card_id',
          ignoreDuplicates: true,
        );
  }

  Future<void> unsaveCard(String cardId) async {
    final me = _client.auth.currentUser!.id;
    await _client
        .from('saved_cards')
        .delete()
        .eq('owner_id', me)
        .eq('card_id', cardId);
  }

  /// Statistiques de profil (amis, posts, cards 7 jours) — RLS : soi + amis.
  Future<({int friends, int posts, int cardsWeek})?> profileStats(
    String userId,
  ) async {
    final rows =
        await _client.rpc('profile_stats', params: {'target': userId}) as List;
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

/// Mes Enregistrements, cards jointes, plus récents d'abord.
final savedCardsProvider = FutureProvider<List<SavedCard>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('saved_cards')
      .select('*, cards(*)')
      .order('created_at', ascending: false);
  return rows.map(SavedCard.fromJson).where((s) => s.card != null).toList();
});

/// La card [cardId] est-elle déjà dans mes Enregistrements ?
final isCardSavedProvider = FutureProvider.family<bool, String>((
  ref,
  cardId,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return false;
  final row = await ref
      .watch(supabaseProvider)
      .from('saved_cards')
      .select('card_id')
      .eq('card_id', cardId)
      .maybeSingle();
  return row != null;
});

class SavedCard {
  const SavedCard({required this.cardId, required this.savedAt, this.card});
  final String cardId;
  final DateTime savedAt;
  final CardModel? card;

  factory SavedCard.fromJson(Map<String, dynamic> json) => SavedCard(
    cardId: json['card_id'] as String,
    savedAt: DateTime.parse(json['created_at'] as String),
    card: json['cards'] == null
        ? null
        : CardModel.fromJson(json['cards'] as Map<String, dynamic>),
  );
}

final cardsRepositoryProvider = Provider((ref) => CardsRepository(ref));
