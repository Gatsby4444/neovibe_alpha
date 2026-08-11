import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/moderation.dart';
import '../../core/theme.dart';
import '../../core/widgets/avatar.dart';

/// Les personnes bloquées, et le moyen de les débloquer.
///
/// Un blocage doit toujours être **réversible et visible par celui qui l'a
/// posé** : sans cet écran, on bloquerait quelqu'un sans jamais pouvoir
/// revenir dessus. La liste n'est lisible que par son propriétaire — personne
/// ne peut savoir qui l'a bloqué.
class BlockedScreen extends ConsumerWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blockedProfilesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Personnes bloquées')),
      body: blocked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Erreur : $e'),
          ),
        ),
        data: (list) => list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Tu n\'as bloqué personne.\n\nBloquer quelqu\'un coupe la '
                    'visibilité des contenus dans les deux sens, et empêche '
                    'tout partage de vous relier — même par un ami commun.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted),
                  ),
                ),
              )
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final p = list[i];
                  return ListTile(
                    leading: Avatar(stored: p.avatarUrl, radius: 20),
                    title: Text(p.chatName),
                    trailing: TextButton(
                      onPressed: () async {
                        await ref
                            .read(moderationRepositoryProvider)
                            .unblock(p.id);
                        ref.invalidate(blockedProfilesProvider);
                      },
                      child: const Text('Débloquer'),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
