import 'package:flutter/material.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../proximity/proximity_repository.dart';
import 'connections_repository.dart';

/// Pop-up de demande de connexion entrante (consigne Jay 2026-07-12) :
/// PP + username + tag name du demandeur, boutons Accepter / Annuler.
/// À brancher via `ref.listen(incomingRequestsProvider, ...)` dans un widget
/// toujours monté (HomeShell) — chaque demande n'est montrée qu'une fois,
/// l'historique restant consultable dans la section cœur du Profil.
final _shownRequestIds = <String>{};

void listenForConnectionRequestPopups(WidgetRef ref, BuildContext context) {
  ref.listen(incomingRequestsProvider, (previous, next) {
    final requests = next.value;
    if (requests == null) return;
    for (final request in requests) {
      if (!_shownRequestIds.add(request.id)) continue;
      showDialog<void>(
        context: context,
        builder: (_) =>
            _RequestDialog(requestId: request.id, senderId: request.senderId),
      );
    }
  });
}

class _RequestDialog extends ConsumerWidget {
  const _RequestDialog({required this.requestId, required this.senderId});
  final String requestId;
  final String senderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sender = ref.watch(profileByIdProvider(senderId)).value;
    return AlertDialog(
      title: const Text('Demande de connexion'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Avatar(
            radius: 36,
            stored: sender?.avatarUrl,
            fallback: Text(
              (sender?.displayName ?? '?').characters.first.toUpperCase(),
              style: const TextStyle(fontSize: 24),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            sender?.displayName ?? '…',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (sender?.tagName != null && sender!.tagName!.isNotEmpty)
            Text(
              sender.tagName!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.muted),
            ),
          const SizedBox(height: 4),
          Text(
            'Vous êtes à proximité en ce moment',
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            await ref.read(proximityRepositoryProvider).decline(requestId);
          },
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(context);
            try {
              await ref.read(proximityRepositoryProvider).accept(requestId);
            } catch (e) {
              // La demande a pu expirer entre l'affichage et le tap
            }
          },
          child: const Text('Accepter'),
        ),
      ],
    );
  }
}
