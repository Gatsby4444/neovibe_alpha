import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'ping_store.dart';
import 'net/proximity_controller.dart';

/// Conversation ping : 100 % LOCALE et 100 % BLE (décisions Jay
/// 2026-07-13) — les messages ne touchent jamais le serveur, vivent 12 h
/// sur chaque téléphone, et l'envoi n'est possible qu'en portée BLE.
/// Séparée pour toujours de la messagerie d'amis (aucune migration).
class PingChatScreen extends ConsumerStatefulWidget {
  const PingChatScreen({super.key, required this.peerId, required this.peer});

  final String peerId;
  final PingPeerSnapshot peer;

  @override
  ConsumerState<PingChatScreen> createState() => _PingChatScreenState();
}

class _PingChatScreenState extends ConsumerState<PingChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  PingConversation? _conversation;
  var _sending = false;

  /// Capturé à l'initialisation : `ref` est INTERDIT dans `dispose()` (le
  /// widget est déjà démonté — Riverpod lève « Using "ref" when a widget is
  /// about to or has been unmounted », vu dans le journal de Jay).
  late final _store = ref.read(pingStoreProvider);

  @override
  void initState() {
    super.initState();
    _store.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _store.removeListener(_reload);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final conv = await _store.conversation(widget.peerId);
    if (!mounted) return;
    setState(() => _conversation = conv);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(proximityControllerProvider.notifier)
          .sendMessage(widget.peerId, text);
      _input.clear();
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inRange = ref.watch(peerInRangeProvider(widget.peerId));
    final messages = _conversation?.messages ?? const <PingMessage>[];
    // ⚠️ **Le verrou d'émission n'existe QUE face à un inconnu.**
    //
    // Il double la règle du destinataire, et pour la même raison : empêcher un
    // inconnu d'insister. Entre amis, il transformait une conversation normale
    // en impasse — Jay, au test du 2026-08-16 : « les deux chats sont bloqués ».
    //
    // ⚠️ Le pire était l'issue : le déblocage exigeait une réponse, et la
    // réponse était précisément ce que la règle d'en face interdisait. Deux
    // verrous qui se tenaient l'un l'autre.
    final isFriend =
        ref
            .watch(proximityControllerProvider)
            .value
            ?.peers
            .any((p) => p.userId == widget.peerId && p.isFriend) ??
        false;
    final blocked =
        !isFriend &&
        (_conversation?.unansweredOutgoing ?? 0) >= PingStore.unansweredLimit;
    final refused = ref
        .read(proximityControllerProvider.notifier)
        .wasRejectedBy(widget.peerId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peer.displayName, style: const TextStyle(fontSize: 17)),
            Text(
              inRange ? 'À proximité' : 'Hors de portée',
              style: TextStyle(
                fontSize: 12,
                color: inRange ? Colors.greenAccent : context.faint,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'Conversation 100 % locale, d\'appareil à appareil — rien ne '
              'passe par internet. Les messages s\'effacent après 12 h.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.faint, fontSize: 11),
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      'Dis bonjour — vous êtes au même endroit.',
                      style: TextStyle(color: context.muted),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) =>
                        _Bubble(message: messages[index]),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: inRange && !blocked,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: !inRange
                            ? 'Hors de portée — recroisez-vous'
                            : refused
                            ? 'Ton dernier message a été refusé — attends sa réponse'
                            : blocked
                            ? 'Attends une réponse (3 messages max)'
                            : 'Message…',
                        // Champ en pilule : le rayon 24 lui est propre, mais
                        // les couleurs viennent du thème. Écrites en `border`
                        // seul, elles étaient noires — et de toute façon
                        // ignorées, `enabledBorder` du thème l'emportant.
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(
                            color: NeoTheme.accentPink,
                            width: 1.8,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: inRange && !blocked && !_sending ? _send : null,
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final PingMessage message;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat.Hm().format(message.at);
    return Align(
      alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: message.mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message.text),
            const SizedBox(height: 2),
            Text(time, style: TextStyle(fontSize: 10, color: context.faint)),
          ],
        ),
      ),
    );
  }
}
