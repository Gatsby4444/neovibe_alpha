import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/profile.dart';
import '../../../core/supabase_providers.dart';
import '../../connections/connections_repository.dart';
import '../../library/library_repository.dart';
import '../../stories/stories_repository.dart';
import '../settings_common.dart';

/// Qui voit quoi : stories et bibliothèque.
///
/// Les deux sont réunies parce qu'elles répondent à **la même question** — la
/// portée de ce que je publie — alors qu'elles étaient séparées par trois
/// autres sujets dans l'écran unique d'avant le 2026-08-13.
class SharingSettingsScreen extends ConsumerWidget {
  const SharingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Partage et visibilité')),
      body: ListView(
        children: [
          const SettingsHeader('Mes stories'),
          SwitchListTile(
            title: const Text('Stories publiques'),
            subtitle: const Text(
              'Désactivé : seuls tes amis voient tes stories. Activé : les '
              'personnes que tu as croisées physiquement dans les dernières '
              '24 h les voient aussi. Le croisement doit être certifié — on '
              'ne peut pas prétendre t\'avoir croisé.',
            ),
            value: profile?.storiesPublic ?? false,
            onChanged: (v) async {
              await ref.read(storiesRepositoryProvider).setStoriesPublic(v);
            },
          ),
          const Divider(),
          const SettingsHeader('Ma bibliothèque'),
          RadioGroup<LibraryVisibility>(
            groupValue: profile?.libraryVisibility,
            onChanged: (v) async {
              if (v == null) return;
              await ref.read(libraryRepositoryProvider).setVisibility(v);
              ref.invalidate(myProfileProvider);
            },
            child: const Column(
              children: [
                RadioListTile<LibraryVisibility>(
                  value: LibraryVisibility.connections,
                  title: Text('Visible par toutes mes connexions'),
                ),
                RadioListTile<LibraryVisibility>(
                  value: LibraryVisibility.restricted,
                  title: Text('Accès restreint (liste choisie)'),
                ),
              ],
            ),
          ),
          if (profile?.libraryVisibility == LibraryVisibility.restricted)
            const _AccessListEditor(),
        ],
      ),
    );
  }
}

/// Liste d'accès restreint : cocher les connexions autorisées.
class _AccessListEditor extends ConsumerWidget {
  const _AccessListEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);
    final granted = ref.watch(libraryAccessProvider).value ?? [];

    return Column(
      children: [
        for (final connection in connections)
          _AccessTile(
            peerId: connection.peerIdFor(me),
            granted: granted.contains(connection.peerIdFor(me)),
          ),
      ],
    );
  }
}

class _AccessTile extends ConsumerWidget {
  const _AccessTile({required this.peerId, required this.granted});
  final String peerId;
  final bool granted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return CheckboxListTile(
      dense: true,
      value: granted,
      title: Text(profile?.displayName ?? '…'),
      onChanged: (v) async {
        final repo = ref.read(libraryRepositoryProvider);
        if (v == true) {
          await repo.grantAccess(peerId);
        } else {
          await repo.revokeAccess(peerId);
        }
        ref.invalidate(libraryAccessProvider);
      },
    );
  }
}
