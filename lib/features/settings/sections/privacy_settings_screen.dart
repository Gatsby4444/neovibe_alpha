import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../blocked_screen.dart';
import '../settings_common.dart';
import '../../profile/profile_repository.dart';

/// Sécurité, blocages et notifications de croisement.
class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Sécurité et confidentialité')),
      body: ListView(
        children: [
          const SettingsHeader('Personnes'),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Personnes bloquées'),
            subtitle: const Text(
              'Coupe la visibilité des contenus dans les deux sens, et empêche '
              'tout partage de vous relier',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BlockedScreen())),
          ),
          const Divider(),
          const SettingsHeader('Waves — « le presque »'),
          SwitchListTile(
            title: const Text('Notifications en temps réel'),
            subtitle: const Text(
              'Par défaut, tu es prévenu après coup. Active pour savoir sur le '
              'moment.',
            ),
            value: profile?.realtimeWaves ?? false,
            onChanged: (v) async =>
                ref.read(profileRepositoryProvider).setRealtimeWaves(v),
          ),
          const SettingsNote(
            'L\'historique des croisements manqués vit dans Profil → ♥',
          ),
        ],
      ),
    );
  }
}
