import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/card.dart';
import '../../core/models/connection.dart';
import '../../core/models/message.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../cards/card_viewer_screen.dart';
import '../cards/cards_repository.dart';
import '../connections/connections_repository.dart';
import 'video_player_screen.dart';
import '../proximity/ble_service.dart';
import 'conversations_repository.dart';
import 'group_settings_screen.dart';

/// Détail d'une conversation (métadonnées + membres).
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

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  RealtimeChannel? _typingChannel;
  Timer? _typingReset;
  String? _typingName;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _setupTypingChannel();
  }

  void _setupTypingChannel() {
    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser!.id;
    _typingChannel = client.channel('typing:${widget.conversationId}')
      ..onBroadcast(
        event: 'typing',
        callback: (payload) {
          final sender = payload['user_id'] as String?;
          if (sender == me) return;
          setState(() => _typingName = payload['name'] as String?);
          _typingReset?.cancel();
          _typingReset = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _typingName = null);
          });
        },
      )
      ..subscribe();
  }

  void _notifyTyping() {
    // Sobriété : un signal toutes les 3 s maximum
    if (DateTime.now().difference(_lastTypingSent).inSeconds < 3) return;
    _lastTypingSent = DateTime.now();
    final me = ref.read(supabaseProvider).auth.currentUser!.id;
    final myProfile = ref.read(myProfileProvider).value;
    _typingChannel?.sendBroadcastMessage(
      event: 'typing',
      payload: {'user_id': me, 'name': myProfile?.displayName ?? ''},
    );
  }

  @override
  void dispose() {
    _typingReset?.cancel();
    _typingChannel?.unsubscribe();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    _input.clear();
    try {
      await ref
          .read(conversationsRepositoryProvider)
          .sendText(widget.conversationId, body);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      }
    }
  }

  Future<void> _sendMedia(bool video) async {
    final picker = ImagePicker();
    final picked = video
        ? await picker.pickVideo(
            source: ImageSource.camera,
            maxDuration: const Duration(seconds: 30),
          )
        : await picker.pickImage(
            source: ImageSource.camera,
            imageQuality: 85,
            maxWidth: 1600,
          );
    if (picked == null) return;
    try {
      await ref
          .read(conversationsRepositoryProvider)
          .sendMedia(
            widget.conversationId,
            File(picked.path),
            video ? MessageKind.video : MessageKind.image,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      }
    }
  }

  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('Limite de 3 messages')) {
      return 'Limite atteinte : 3 messages sans réponse. '
          'Le canal se rouvrira à votre prochaine rencontre.';
    }
    if (text.contains('texte')) {
      return 'Le canal de proximité est limité au texte.';
    }
    return 'Envoi impossible : $text';
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final detail = ref.watch(conversationDetailProvider(widget.conversationId));
    final messages = ref.watch(messagesStreamProvider(widget.conversationId));

    // Marque comme lus les messages reçus dès qu'ils arrivent à l'écran
    ref.listen(messagesStreamProvider(widget.conversationId), (_, next) {
      final list = next.value;
      if (list != null && list.isNotEmpty) {
        ref.read(conversationsRepositoryProvider).markRead(list);
      }
    });

    final conversation = detail.value;
    final isProximity = conversation?.type == ConversationType.proximity;
    final isGroup = conversation?.type == ConversationType.group;
    final peer = conversation?.otherMember(me);

    // Lien partiel éventuel avec ce pair (canal proximité)
    final partials = ref.watch(partialConnectionsProvider);
    final partial = peer == null
        ? null
        : partials.where((c) => c.peerIdFor(me) == peer.id).firstOrNull;

    // Canal proximité : visible uniquement en portée BLE, sauf lien établi
    final ble = ref.watch(bleServiceProvider);
    final outOfRange =
        isProximity &&
        peer != null &&
        partial == null &&
        !ble.nearby.values.any((u) => u.userId == peer.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(conversation?.displayName(me) ?? '…'),
        actions: [
          if (isGroup)
            IconButton(
              icon: const Icon(Icons.group),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupSettingsScreen(
                    conversationId: widget.conversationId,
                  ),
                ),
              ),
            ),
        ],
        bottom: isProximity
            ? PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Container(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Canal de proximité — texte uniquement, 3 messages max sans réponse',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              )
            : null,
      ),
      body: Column(
        children: [
          if (partial != null) _PartialBanner(partial: partial, me: me),
          if (outOfRange)
            Container(
              width: double.infinity,
              color: Colors.orange.withValues(alpha: 0.15),
              padding: const EdgeInsets.all(10),
              child: const Text(
                'Hors de portée — ce canal se fermera sans échange mutuel.',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Erreur : $e')),
              data: (list) => ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final message = list[list.length - 1 - index];
                  return _MessageBubble(
                    message: message,
                    isMine: message.senderId == me,
                  );
                },
              ),
            ),
          ),
          if (_typingName != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Row(
                children: [
                  Text(
                    '$_typingName est en train d\'écrire…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  if (!isProximity) ...[
                    IconButton(
                      icon: const Icon(Icons.photo_camera),
                      onPressed: () => _sendMedia(false),
                    ),
                    IconButton(
                      icon: const Icon(Icons.videocam),
                      onPressed: () => _sendMedia(true),
                    ),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onChanged: (_) => _notifyTyping(),
                      onSubmitted: (_) => _sendText(),
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Message éphémère (24 h)…',
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendText,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau de lien partiel : 3 jours pour confirmer des deux côtés (spec 4.4).
class _PartialBanner extends ConsumerWidget {
  const _PartialBanner({required this.partial, required this.me});
  final Connection partial;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final confirmed = partial.confirmedBy(me);
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Text(
            'Lien partiel — expire dans ${remaining(partial.partialExpiresAt!)}. '
            'Confirmez tous les deux pour devenir de vraies connexions.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          confirmed
              ? const Text('✓ Tu as confirmé — en attente de l\'autre')
              : FilledButton.tonal(
                  onPressed: () => ref
                      .read(connectionsRepositoryProvider)
                      .confirmPartial(partial.id),
                  child: const Text('Confirmer la connexion'),
                ),
        ],
      ),
    );
  }
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({required this.message, required this.isMine});
  final Message message;
  final bool isMine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final senderProfile = isMine
        ? null
        : ref.watch(profileByIdProvider(message.senderId)).value;

    Widget content;
    switch (message.kind) {
      case MessageKind.text:
        content = Text(message.body ?? '');
      case MessageKind.image:
      case MessageKind.video:
        content = _MediaPreview(message: message);
      case MessageKind.card:
        content = _CardChip(message: message);
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMine ? scheme.primaryContainer : const Color(0xFF1E1E28),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMine && senderProfile != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  senderProfile.displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                ),
              ),
            content,
            const SizedBox(height: 2),
            Text(
              '${shortTime(message.createdAt)} · disparaît dans ${remaining(message.expiresAt)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white38,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaPreview extends ConsumerWidget {
  const _MediaPreview({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (message.mediaPath == null) return const Text('[média]');
    final url = ref.watch(_mediaUrlProvider(message.mediaPath!));
    return url.when(
      loading: () => const SizedBox(
        height: 120,
        width: 120,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => const Text('[média indisponible]'),
      data: (link) => message.kind == MessageKind.image
          ? ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                link,
                height: 220,
                fit: BoxFit.cover,
                width: 220,
              ),
            )
          : _InlineVideo(url: link),
    );
  }
}

final _mediaUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref
      .watch(supabaseProvider)
      .storage
      .from('media')
      .createSignedUrl(path, 3600),
);

class _InlineVideo extends StatelessWidget {
  const _InlineVideo({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.play_circle),
      label: const Text('Vidéo'),
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => VideoPlayerScreen(url: url))),
    );
  }
}

/// Pastille Card dans une conversation : tag + couleur du type,
/// ouverture dans le viewer (avec règles Oneshot/Hot).
class _CardChip extends ConsumerWidget {
  const _CardChip({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card =
        message.card ??
        (message.cardId == null
            ? null
            : ref.watch(_cardProvider(message.cardId!)).value);
    if (card == null) {
      return const Text(
        '[Card expirée ou détruite]',
        style: TextStyle(fontStyle: FontStyle.italic, color: Colors.white38),
      );
    }
    final isMine = card.ownerId == ref.watch(currentUserIdProvider);
    // Émetteur : demandes de replay en attente sur cette card
    final pendingReplays = isMine
        ? (ref.watch(pendingReplayForCardProvider(card.id)).value ??
              <CardDelivery>[])
        : <CardDelivery>[];
    final onGradient = card.type.gradient != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => CardViewerScreen(card: card)),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: card.type.gradient,
              border: onGradient
                  ? null
                  : Border.all(color: card.type.color, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.style,
                  color: onGradient ? Colors.white : card.type.color,
                ),
                const SizedBox(width: 8),
                Text(
                  card.type.tag,
                  style: TextStyle(
                    color: onGradient ? Colors.white : card.type.color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Ouvrir'),
              ],
            ),
          ),
        ),
        // Replay : le destinataire demande, l'émetteur décide
        // (jamais automatique — décision verrouillée du produit)
        for (final delivery in pendingReplays)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Replay demandé — accorder'),
              onPressed: () async {
                try {
                  await ref
                      .read(cardsRepositoryProvider)
                      .grantReplay(delivery.id);
                  ref.invalidate(pendingReplayForCardProvider(card.id));
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                  }
                }
              },
            ),
          ),
      ],
    );
  }
}

final _cardProvider = FutureProvider.family<CardModel?, String>((
  ref,
  id,
) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('cards')
      .select()
      .eq('id', id)
      .maybeSingle();
  return row == null ? null : CardModel.fromJson(row);
});
