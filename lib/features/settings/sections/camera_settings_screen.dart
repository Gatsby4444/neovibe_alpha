import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../settings_common.dart';

/// Réglages de prise de vue.
class CameraSettingsScreen extends ConsumerWidget {
  const CameraSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Caméra')),
      body: ListView(
        children: [
          const SettingsHeader('Aperçu'),
          SwitchListTile(
            title: const Text('Miroir de la caméra frontale'),
            subtitle: const Text(
              'Activé : tu te vois comme dans un miroir. Désactivé : comme les '
              'autres te voient (les lettres sont lisibles). Ne change que '
              'l\'aperçu, jamais la photo enregistrée.',
            ),
            value: ref.watch(selfieMirrorProvider),
            onChanged: (v) => ref.read(selfieMirrorProvider.notifier).set(v),
          ),
        ],
      ),
    );
  }
}
