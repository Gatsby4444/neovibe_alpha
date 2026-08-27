import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/clock.dart';
import '../../core/derived_list.dart';
import '../../core/diagnostics/app_log.dart';
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
  // ⚠️ **Un canal de proximité VIDE ne figure pas dans la liste.**
  //
  // Décision de Jay du 2026-08-27 : *« après 24 h sans échange il disparaît de
  // la liste (lorsqu'il n'y a plus aucun contenu) »*. Les messages expirent à
  // 24 h : un canal sans message est donc soit tout juste ouvert et jamais
  // utilisé, soit vieux de plus de 24 heures. Dans les deux cas il n'a rien à
  // montrer.
  //
  // ⚠️ **Ce filtre ne fait que devancer la purge**, il ne la remplace pas : le
  // cron `neovibe_purge_proximity_conversations` supprime réellement la ligne
  // cinq minutes après sa création si elle est restée vide. Le filtre existe
  // pour que l'écran ne montre rien pendant ces cinq minutes — masquer sans
  // supprimer laisserait une `pair_key` qui empêche d'en rouvrir une.
  result.removeWhere(
    (c) => c.type == ConversationType.proximity && c.lastMessage == null,
  );

  // Conversations avec activité récente d'abord
  result.sort(
    (a, b) => (b.lastMessage?.createdAt ?? b.createdAt).compareTo(
      a.lastMessage?.createdAt ?? a.createdAt,
    ),
  );
  return result;
});

/// **L'ACQUISITION** — les messages d'une conversation, tels qu'ils sont.
///
/// ⚠️ **Ne filtre rien et n'a plus de minuterie**, depuis le 2026-08-25
/// (checkup `RAPPELS.md` #52).
///
/// Ce provider rejouait son filtre d'expiration toutes les 10 secondes, en
/// réémettant une `List` neuve. Deux défauts en un :
///
/// 1. **Il décidait de ce qui est VISIBLE.** La péremption est une décision
///    d'affichage : elle dépend d'une horloge, pas de la table.
/// 2. **Il imposait son rythme à tous ses lecteurs** — 360 réveils par heure,
///    chat ouvert et parfaitement inactif — et un futur second lecteur en
///    aurait hérité sans l'avoir demandé.
///
/// La péremption vit maintenant dans [visibleMessagesProvider], qui observe
/// l'horloge de `core/clock.dart` et ne réveille personne tant que la liste ne
/// change pas. Côté serveur, la RLS rend déjà le message invisible dès
/// `expires_at` et la purge cron le supprime dans les 5 minutes.
final messagesStreamProvider = StreamProvider.family<List<Message>, String>((
  ref,
  conversationId,
) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  return client
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('conversation_id', conversationId)
      // ATTENTION : sur un stream, order() est DESCENDANT par défaut
      // (l'inverse du REST) — c'est ce qui empilait les messages en haut
      // du chat (bug remonté par Jay, 2026-07-12).
      .order('created_at', ascending: true)
      .map((rows) => rows.map(Message.fromJson).toList(growable: false));
});

/// **L'USAGE** — ce que le chat affiche à cet instant.
///
/// Deux sources, deux rythmes : les messages (quand quelqu'un écrit) et
/// l'horloge de péremption (toutes les 5 s). L'horloge bat sans rien réveiller
/// tant qu'aucun message n'atteint son échéance — c'est [DerivedList] qui
/// arrête la propagation.
///
/// ⚠️ **C'est ici que se corrige la « disparition buggée » signalée par Jay le
/// 2026-07-13**, et cette fois sans imposer de rythme à l'acquisition.
final visibleMessagesProvider = Provider.family<ValueList<Message>, String>((
  ref,
  conversationId,
) {
  final now = ref.watch(expiryClockProvider);
  final tous = ref.watch(messagesStreamProvider(conversationId)).value;
  if (tous == null) return const ValueList.empty();
  return ValueList(
    tous.where((m) => m.expiresAt.isAfter(now)).toList(growable: false),
  );
});

/// Détail d'une conversation (métadonnées + membres).
///
/// ⚠️ **Déplacé depuis `chat_screen.dart` le 2026-08-25** (checkup #52). Une
/// requête écrite dans le fichier d'un écran n'est réutilisable par personne, et
/// ajouter un champ à l'écran obligeait à toucher au code qui parle au réseau —
/// exactement la question de contrôle de la règle.
final conversationDetailProvider = FutureProvider.family<Conversation, String>((
  ref,
  id,
) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('conversations')
      .select('*, members:conversation_members(profiles(*))')
      .eq('id', id)
      .single();
  return Conversation.fromJson(row);
});

/// URL signée d'un média de message. Même origine, même motif.
final messageMediaUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref
      .watch(supabaseProvider)
      .storage
      .from('media')
      .createSignedUrl(path, 3600),
);

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

  /// Crée un groupe.
  ///
  /// Passe par une RPC depuis le 2026-08-10, comme les conversations directes
  /// et de proximité juste au-dessus — les groupes étaient les seuls à faire
  /// des insertions brutes, et c'est ce qui les cassait.
  ///
  /// **Le bug** (erreur 42501 relevée par Jay) : l'ancien code faisait
  /// `.insert({...}).select().single()`. Le `.select()` ajoute un `RETURNING`,
  /// et PostgreSQL applique alors la politique **SELECT** à la ligne renvoyée.
  /// Or celle-ci exige d'être membre de la conversation — ce que le créateur ne
  /// devient qu'à l'insertion SUIVANTE. La ligne était créée puis refusée au
  /// retour, et le message d'erreur accusait à tort la politique d'insertion.
  ///
  /// La RPC rend en prime la création **atomique** : conversation, créateur et
  /// membres en une transaction, au lieu de trois allers-retours dont les
  /// derniers pouvaient échouer en laissant un groupe à moitié formé.
  Future<String> createGroup(String title, List<String> memberIds) =>
      AppLog.instance.trace('create_group_conversation', () async {
        final id = await _client.rpc(
          'create_group_conversation',
          params: {'p_title': title, 'p_member_ids': memberIds},
        );
        return id as String;
      }, details: '${memberIds.length} membre(s)');

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
