import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import 'chat_screen.dart';
import 'conversations_repository.dart';

/// Création de groupe : uniquement à partir de connexions existantes (spec 4.7).
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _title = TextEditingController();
  final _selected = <String>{};
  var _loading = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty || _selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nom du groupe et au moins un membre requis.'),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final convId = await ref
          .read(conversationsRepositoryProvider)
          .createGroup(title, _selected.toList());
      ref.invalidate(conversationsProvider);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ChatScreen(conversationId: convId)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau groupe')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _title,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Nom du groupe'),
            ),
          ),
          Expanded(
            child: connections.isEmpty
                ? Center(
                    child: Text(
                      'Aucune connexion pour l\'instant.',
                      style: TextStyle(color: context.muted),
                    ),
                  )
                : ListView(
                    children: [
                      for (final connection in connections)
                        _MemberTile(
                          peerId: connection.peerIdFor(me),
                          selected: _selected.contains(
                            connection.peerIdFor(me),
                          ),
                          onChanged: (checked) => setState(() {
                            final id = connection.peerIdFor(me);
                            checked ? _selected.add(id) : _selected.remove(id);
                          }),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _loading ? null : _create,
                child: Text('Créer (${_selected.length} membres)'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
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
