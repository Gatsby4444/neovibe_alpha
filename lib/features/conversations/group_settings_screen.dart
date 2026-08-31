import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/avatar.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import 'conversations_repository.dart';

/// Gestion basique de groupe V1 : renommage, ajout (parmi SES connexions),
/// retrait de membres, quitter (spec 4.7 — pas de rôles avancés).
class GroupSettingsScreen extends ConsumerWidget {
  const GroupSettingsScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final detail = ref.watch(conversationDetailProvider(conversationId));

    return Scaffold(
      appBar: AppBar(title: const Text('Groupe')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (conv) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(conv.title ?? 'Groupe'),
              subtitle: const Text('Renommer'),
              onTap: () async {
                final controller = TextEditingController(text: conv.title);
                final newTitle = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Renommer le groupe'),
                    content: TextField(controller: controller, maxLength: 80),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Annuler'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.pop(context, controller.text.trim()),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
                if (newTitle != null && newTitle.isNotEmpty) {
                  await ref
                      .read(conversationsRepositoryProvider)
                      .renameGroup(conversationId, newTitle);
                  ref.invalidate(conversationDetailProvider(conversationId));
                  ref.invalidate(conversationsProvider);
                }
              },
            ),
            const Divider(),
            Text(
              'Membres (${conv.members.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final member in conv.members)
              ListTile(
                leading: Avatar(
                  stored: member.avatarUrl,
                  fallback: Text(
                    member.displayName.characters.first.toUpperCase(),
                  ),
                ),
                title: Text(
                  member.id == me
                      ? '${member.displayName} (moi)'
                      : member.displayName,
                ),
                // 🔴 **LE BOUTON N'APPARAÎT QUE S'IL PEUT AGIR — 2026-08-31.**
                //
                // La règle serveur est passée à « soi-même, ou le créateur »
                // (décision de Jay). Cet écran offrait « Retirer » à TOUT le
                // monde, et l'échec aurait été **muet** : un `delete` refusé
                // par la sécurité au niveau des lignes ne lève pas, il
                // supprime zéro ligne et répond « ok ». L'écran se serait
                // rechargé avec le membre toujours là, sans un mot.
                //
                // ⚠️ C'est le « mur sans issue » de `CLAUDE.md` : un bouton
                // dont le seul effet possible est de ne rien faire est pire
                // qu'un bouton absent — il fait douter de l'app, pas de soi.
                trailing: (member.id == me || conv.createdBy != me)
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: 'Retirer',
                        onPressed: () async {
                          await ref
                              .read(conversationsRepositoryProvider)
                              .removeMember(conversationId, member.id);
                          ref.invalidate(
                            conversationDetailProvider(conversationId),
                          );
                        },
                      ),
              ),
            const SizedBox(height: 8),
            _AddMemberSection(
              conversationId: conversationId,
              existingIds: conv.members.map((m) => m.id).toSet(),
            ),
            const Divider(height: 32),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () async {
                await ref
                    .read(conversationsRepositoryProvider)
                    .removeMember(conversationId, me);
                ref.invalidate(conversationsProvider);
                if (context.mounted) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                }
              },
              child: const Text('Quitter le groupe'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddMemberSection extends ConsumerWidget {
  const _AddMemberSection({
    required this.conversationId,
    required this.existingIds,
  });
  final String conversationId;
  final Set<String> existingIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final candidates = ref
        .watch(fullConnectionsProvider)
        .map((c) => c.peerIdFor(me))
        .where((id) => !existingIds.contains(id))
        .toList();

    if (candidates.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      leading: const Icon(Icons.person_add),
      title: const Text('Ajouter une de mes connexions'),
      children: [
        for (final id in candidates)
          _CandidateTile(peerId: id, conversationId: conversationId),
      ],
    );
  }
}

class _CandidateTile extends ConsumerWidget {
  const _CandidateTile({required this.peerId, required this.conversationId});
  final String peerId;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return ListTile(
      title: Text(profile?.displayName ?? '…'),
      trailing: const Icon(Icons.add),
      onTap: () async {
        await ref
            .read(conversationsRepositoryProvider)
            .addMember(conversationId, peerId);
        ref.invalidate(conversationDetailProvider(conversationId));
      },
    );
  }
}
