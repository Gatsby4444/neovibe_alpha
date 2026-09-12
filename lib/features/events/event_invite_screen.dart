import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/top_banner.dart';
import '../connections/connections_repository.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **Inviter à un événement privé** — mes amis, au sens strict, et ceux
/// qui n'y sont pas encore. Le serveur refuse tout autre nom
/// (`invite_to_event` : `are_connected`).
class EventInviteScreen extends ConsumerStatefulWidget {
  const EventInviteScreen({super.key, required this.eventId});
  final String eventId;

  @override
  ConsumerState<EventInviteScreen> createState() => _EventInviteScreenState();
}

class _EventInviteScreenState extends ConsumerState<EventInviteScreen> {
  final _selected = <String>{};
  var _loading = false;

  Future<void> _invite() async {
    if (_selected.isEmpty) return;
    setState(() => _loading = true);
    final repo = ref.read(eventsRepositoryProvider);
    var ok = 0;
    for (final id in _selected) {
      try {
        await repo.invite(widget.eventId, id);
        ok++;
      } catch (e) {
        if (mounted) {
          TopBanner.show(
            context,
            messageServeur(e),
            tone: TopBannerTone.already,
          );
        }
      }
    }
    if (!mounted) return;
    if (ok > 0) {
      TopBanner.show(
        context,
        '$ok invitation${ok > 1 ? 's' : ''} envoyée'
        '${ok > 1 ? 's' : ''}.',
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendProfilesProvider);
    final people = ref.watch(eventPeopleProvider(widget.eventId));
    final deja = {
      for (final p in people.value ?? const [])
        if (p.invited) p.userId,
    };
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Inviter'),
        actions: [
          TextButton(
            onPressed: _loading || _selected.isEmpty ? null : _invite,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('Inviter (${_selected.length})'),
          ),
        ],
      ),
      body: friends.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(messageServeur(e)),
        ),
        data: (map) {
          final list = map.values.where((f) => !deja.contains(f.id)).toList()
            ..sort((a, b) => a.chatName.compareTo(b.chatName));
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Tous tes amis sont déjà invités.',
                style: TextStyle(color: context.muted),
              ),
            );
          }
          return ListView(
            children: [
              for (final f in list)
                CheckboxListTile(
                  value: _selected.contains(f.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(f.id);
                    } else {
                      _selected.remove(f.id);
                    }
                  }),
                  secondary: Avatar(
                    stored: f.avatarUrl,
                    radius: 20,
                    fallback: Text(f.chatName.characters.first.toUpperCase()),
                  ),
                  title: Text(f.chatName),
                  activeColor: p.action,
                ),
            ],
          );
        },
      ),
    );
  }
}
