import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import 'cards_repository.dart';

/// Destination d'une Card : destinataires (connexions) et/ou bibliothèque.
/// One of One : un seul destinataire, pas de bibliothèque.
/// Oneshot : pas de bibliothèque (vue unique).
class CardSendScreen extends ConsumerStatefulWidget {
  const CardSendScreen({
    super.key,
    required this.front,
    required this.back,
    required this.type,
    this.oneshotDuration = 3,
  });

  final File front;
  final File back;
  final CardType type;
  final int oneshotDuration;

  @override
  ConsumerState<CardSendScreen> createState() => _CardSendScreenState();
}

class _CardSendScreenState extends ConsumerState<CardSendScreen> {
  final _selected = <String>{};
  var _publish = false;
  var _loading = false;

  bool get _canPublish =>
      widget.type != CardType.oneOfOne && widget.type != CardType.oneshot;

  Future<void> _send() async {
    if (_selected.isEmpty && !_publish) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choisis au moins un destinataire ou publie.'),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final repo = ref.read(cardsRepositoryProvider);
      final card = await repo.create(
        front: widget.front,
        back: widget.back,
        type: widget.type,
        viewDurationSeconds: widget.oneshotDuration,
      );
      if (_selected.isNotEmpty) {
        await repo.send(card, _selected.toList());
      }
      if (_publish) {
        await repo.publishToLibrary(card);
      }
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Card envoyée ✓')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);
    final singleRecipient = widget.type == CardType.oneOfOne;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Envoyer '),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: widget.type.color),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.type.tag,
                style: TextStyle(
                  color: widget.type.color,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (singleRecipient)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Card exclusive : un seul destinataire, pour toujours.',
                style: TextStyle(color: Color(0xFFD4AF37)),
              ),
            ),
          if (_canPublish)
            SwitchListTile(
              title: const Text('Publier dans ma bibliothèque'),
              subtitle: const Text(
                'Contenu conservé, visible selon tes règles',
              ),
              value: _publish,
              onChanged: (v) => setState(() => _publish = v),
            ),
          const Divider(),
          Expanded(
            child: connections.isEmpty
                ? const Center(
                    child: Text(
                      'Aucune connexion à qui envoyer.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView(
                    children: [
                      for (final connection in connections)
                        _RecipientTile(
                          peerId: connection.peerIdFor(me),
                          selected: _selected.contains(
                            connection.peerIdFor(me),
                          ),
                          onChanged: (checked) => setState(() {
                            final id = connection.peerIdFor(me);
                            if (checked) {
                              if (singleRecipient) _selected.clear();
                              _selected.add(id);
                            } else {
                              _selected.remove(id);
                            }
                          }),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _loading ? null : _send,
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Envoyer'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipientTile extends ConsumerWidget {
  const _RecipientTile({
    required this.peerId,
    required this.selected,
    required this.onChanged,
  });
  final String peerId;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => onChanged(v ?? false),
      title: Text(profile?.displayName ?? '…'),
      secondary: CircleAvatar(
        backgroundImage: profile?.avatarUrl == null
            ? null
            : NetworkImage(profile!.avatarUrl!),
        child: profile?.avatarUrl == null
            ? Text((profile?.displayName ?? '?').characters.first.toUpperCase())
            : null,
      ),
    );
  }
}
