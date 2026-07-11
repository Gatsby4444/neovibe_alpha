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
  Future<CardModel> create({
    required File front,
    required File back,
    required CardType type,
    int? viewDurationSeconds,
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
          if (type == CardType.oneshot)
            'view_duration_seconds': viewDurationSeconds ?? 3,
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

  Future<void> publishToLibrary(CardModel card, {String? caption}) async {
    final me = _client.auth.currentUser!.id;
    await _client.from('library_items').insert({
      'owner_id': me,
      'kind': 'card',
      'card_id': card.id,
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

  Future<void> destroyOneshot(String deliveryId) =>
      _client.rpc('destroy_oneshot', params: {'delivery_id': deliveryId});

  Future<String> imageUrl(String path) =>
      _client.storage.from('cards').createSignedUrl(path, 3600);
}

final cardsRepositoryProvider = Provider((ref) => CardsRepository(ref));
