import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../gl_preview_test_screen.dart';
import '../settings_common.dart';

/// Bancs d'essai et déclencheurs manuels.
class DeveloperToolsScreen extends ConsumerWidget {
  const DeveloperToolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Outils')),
      body: ListView(
        children: const [
          SettingsHeader('Caméra'),
          SettingsCategoryTile(
            icon: Icons.view_in_ar,
            title: 'Aperçu GPU (étape 1)',
            subtitle:
                'Rendu OpenGL testé sur UNE caméra. À vérifier : fluide ? '
                'bon sens (pas pivoté ni en miroir) ?',
            builder: _glPreview,
          ),
          Divider(),
          SettingsHeader('BeReal'),
          SettingsNote('En attendant le déclenchement serveur aléatoire.'),
          _DevBerealSection(),
        ],
      ),
    );
  }

  static Widget _glPreview(BuildContext _) => const GlPreviewTestScreen();
}

/// Mode test développeur (temporaire) : déclenche ou programme la
/// notification BeReal, en attendant le déclenchement serveur aléatoire.
class _DevBerealSection extends ConsumerWidget {
  const _DevBerealSection();

  static const _title = 'C\'est le moment. Sois vrai.';
  static const _body = 'Tu as 5 minutes pour capturer ton instant.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifs = ref.watch(notificationServiceProvider);
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.bolt),
          title: const Text('Déclencher la notification BeReal maintenant'),
          onTap: () async {
            await notifs.show(
              NotifChannel.bereal,
              _title,
              _body,
              payload: 'bereal',
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Notification BeReal envoyée')),
              );
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.schedule),
          title: const Text('Programmer la notification BeReal'),
          subtitle: const Text('À la seconde près'),
          onTap: () async {
            final controller = TextEditingController(text: '30');
            final seconds = await showDialog<int>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Dans combien de secondes ?'),
                content: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: const InputDecoration(suffixText: 's'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Annuler'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      int.tryParse(controller.text.trim()),
                    ),
                    child: const Text('Programmer'),
                  ),
                ],
              ),
            );
            if (seconds == null || seconds <= 0) return;
            await notifs.schedule(
              NotifChannel.bereal,
              _title,
              _body,
              DateTime.now().add(Duration(seconds: seconds)),
              payload: 'bereal',
              exact: true,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Notification BeReal dans $seconds s')),
              );
            }
          },
        ),
      ],
    );
  }
}
