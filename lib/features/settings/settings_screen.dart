import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import '../library/library_repository.dart';
import '../waves/waves_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final profile = ref.watch(myProfileProvider).value;
    final client = ref.watch(supabaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        children: [
          const _Header('Waves — "le presque"'),
          SwitchListTile(
            title: const Text('Notifications en temps réel'),
            subtitle: const Text(
              'Par défaut, tu es prévenu après coup. Active pour savoir sur le moment.',
            ),
            value: profile?.realtimeWaves ?? false,
            onChanged: (v) async {
              await client
                  .from('profiles')
                  .update({'realtime_waves': v})
                  .eq('id', me);
              ref.invalidate(myProfileProvider);
            },
          ),
          ListTile(
            leading: const Icon(Icons.waving_hand),
            title: const Text('Historique des croisements manqués'),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const WavesScreen())),
          ),
          const Divider(),
          const _Header('Ma bibliothèque'),
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
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Se déconnecter'),
            onTap: () async {
              await client.auth.signOut();
              if (context.mounted) {
                Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
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
