import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/message.dart';
import '../../core/supabase_providers.dart';

/// Liste de mes conversations avec membres et dernier message.
final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];

  final rows = await client
      .from('conversations')
      .select('*, members:conversation_members(profiles(*))')
      .order('created_at', ascending: false);
  final conversations = rows.map(Conversation.fromJson).toList();

  // Dernier message par conversation (requête groupée simple pour la V1)
  final result = <Conversation>[];
  for (final conv in conversations) {
    final last = await client
        .from('messages')
        .select()
        .eq('conversation_id', conv.id)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    result.add(
      last == null ? conv : conv.copyWith(lastMessage: Message.fromJson(last)),
    );
  }
  // Conversations avec activité récente d'abord
  result.sort(
    (a, b) => (b.lastMessage?.createdAt ?? b.createdAt).compareTo(
      a.lastMessage?.createdAt ?? a.createdAt,
    ),
  );
  return result;
});

/// Messages d'une conversation, temps réel, filtrés des expirés côté client
/// (la RLS et la purge cron les retirent aussi côté serveur).
final messagesStreamProvider = StreamProvider.family<List<Message>, String>((
  ref,
  conversationId,
) {
  final client = ref.watch(supabaseProvider);
  return client
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('conversation_id', conversationId)
      .order('created_at')
      .map(
        (rows) =>
            rows.map(Message.fromJson).where((m) => !m.isExpired).toList(),
      );
});

class ConversationsRepository {
  ConversationsRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  Future<String> getOrCreateDirect(String peerId) async {
    final id = await _client.rpc(
      'get_or_create_direct_conversation',
      params: {'peer': peerId},
    );
    return id as String;
  }

  Future<String> getOrCreateProximity(String peerId) async {
    final id = await _client.rpc(
      'get_or_create_proximity_conversation',
      params: {'peer': peerId},
    );
    return id as String;
  }

  Future<String> createGroup(String title, List<String> memberIds) async {
    final me = _client.auth.currentUser!.id;
    final conv = await _client
        .from('conversations')
        .insert({
          'conversation_type': 'group',
          'title': title,
          'created_by': me,
        })
        .select()
        .single();
    final convId = conv['id'] as String;
    // Le créateur d'abord (policy bootstrap), puis ses connexions
    await _client.from('conversation_members').insert({
      'conversation_id': convId,
      'user_id': me,
    });
    for (final memberId in memberIds) {
      await _client.from('conversation_members').insert({
        'conversation_id': convId,
        'user_id': memberId,
      });
    }
    return convId;
  }

  Future<void> renameGroup(String conversationId, String title) => _client
      .from('conversations')
      .update({'title': title})
      .eq('id', conversationId);

  Future<void> addMember(String conversationId, String userId) => _client
      .from('conversation_members')
      .insert({'conversation_id': conversationId, 'user_id': userId});

  Future<void> removeMember(String conversationId, String userId) => _client
      .from('conversation_members')
      .delete()
      .eq('conversation_id', conversationId)
      .eq('user_id', userId);

  Future<void> sendText(String conversationId, String body) async {
    final me = _client.auth.currentUser!.id;
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': me,
      'kind': 'text',
      'body': body,
    });
  }

  /// Envoi d'un média éphémère (photo/vidéo) dans une conversation.
  Future<void> sendMedia(
    String conversationId,
    File file,
    MessageKind kind,
  ) async {
    final me = _client.auth.currentUser!.id;
    final ext = kind == MessageKind.video ? 'mp4' : 'jpg';
    final contentType = kind == MessageKind.video ? 'video/mp4' : 'image/jpeg';
    final path =
        '$me/${DateTime.now().millisecondsSinceEpoch}_${file.hashCode}.$ext';
    await _client.storage
        .from('media')
        .upload(path, file, fileOptions: FileOptions(contentType: contentType));
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': me,
      'kind': kind.name,
      'media_path': path,
    });
  }

  Future<void> markRead(List<Message> messages) async {
    final me = _client.auth.currentUser!.id;
    final unreadOthers = messages
        .where((m) => m.senderId != me)
        .map((m) => m.id)
        .toList();
    if (unreadOthers.isEmpty) return;
    await _client
        .from('message_reads')
        .upsert(
          unreadOthers.map((id) => {'message_id': id, 'user_id': me}).toList(),
          onConflict: 'message_id,user_id',
          ignoreDuplicates: true,
        );
  }

  /// URL signée pour un média de messagerie.
  Future<String> mediaUrl(String path) =>
      _client.storage.from('media').createSignedUrl(path, 3600);
}

final conversationsRepositoryProvider = Provider(
  (ref) => ConversationsRepository(ref),
);
