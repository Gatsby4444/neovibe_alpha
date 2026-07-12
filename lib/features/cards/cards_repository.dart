import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/card.dart';
import '../../core/supabase_providers.dart';

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
  /// [viewDurationSeconds] null = lecture illimitée ; [maxViews] null = vues
  /// illimitées. Hot : toujours 1 vue (imposé aussi côté serveur).
  Future<CardModel> create({
    required File front,
    required File back,
    required CardType type,
    int? viewDurationSeconds,
    int? maxViews,
    bool saveable = false,
  }) async {
    final me = _client.auth.currentUser!.id;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final frontPath = '$me/${stamp}_front.jpg';
    final backPath = '$me/${stamp}_back.jpg';
    const options = FileOptions(contentType: 'image/jpeg');
    await _client.storage
        .from('cards')
        .upload(frontPath, front, fileOptions: options);
    await _client.storage
        .from('cards')
        .upload(backPath, back, fileOptions: options);

    final row = await _client
        .from('cards')
        .insert({
          'owner_id': me,
          'card_type': type.dbValue,
          'front_path': frontPath,
          'back_path': backPath,
          'view_duration_seconds': type == CardType.hot
              ? 10
              : viewDurationSeconds,
          'max_views': type == CardType.hot ? 1 : maxViews,
          'saveable': type.canBeSaveable && saveable,
        })
        .select()
        .single();
    return CardModel.fromJson(row);
  }

  /// Envoie une Card à des destinataires : livraison + message par conversation.
  /// One of One : un seul destinataire, contrainte re-vérifiée côté serveur.
  Future<void> send(CardModel card, List<String> recipientIds) async {
    final me = _client.auth.currentUser!.id;
    if (card.type == CardType.oneOfOne && recipientIds.length > 1) {
      throw StateError('Une Card 1/1 ne peut avoir qu\'un destinataire');
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

  /// [isPublic] : visible par toute personne accédant au profil par un moyen
  /// légitime (croisement ping, recommandation…) — jamais pour les Hot.
  Future<void> publishToLibrary(
    CardModel card, {
    String? caption,
    bool isPublic = false,
  }) async {
    final me = _client.auth.currentUser!.id;
    await _client.from('library_items').insert({
      'owner_id': me,
      'kind': 'card',
      'card_id': card.id,
      'is_public': isPublic && card.type != CardType.hot,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
    });
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

  /// Fin de visionnage d'une Hot : destruction + disparition du chat.
  Future<void> finishHotView(String deliveryId) =>
      _client.rpc('finish_hot_view', params: {'delivery_id': deliveryId});

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
