import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../../proximity/net/proximity_controller.dart';
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
          SettingsHeader('Ping'),
          _RemiseAZeroPing(),
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

/// Remise à zéro du local du ping — **outil de test**.
///
/// ⚠️ Supprimer une amitié en base ne suffit pas à revenir à « ils ne se sont
/// jamais vus » : le carnet, les conversations ping, les croisements, les
/// demandes et le cooldown des waves vivent **sur l'appareil**. Sans ce bouton,
/// un test de première rencontre repart avec la moitié de la mémoire de la
/// précédente — et ce qu'on observe n'est alors pas une première rencontre.
class _RemiseAZeroPing extends ConsumerWidget {
  const _RemiseAZeroPing();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.restart_alt),
      title: const Text('Remettre le ping à zéro (local)'),
      subtitle: const Text(
        "Carnet d'amis, conversations ping, croisements, demandes et "
        'cooldown des waves. Ne touche pas au serveur.',
      ),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remettre le ping à zéro ?'),
            content: const Text(
              'Tout ce que le ping garde sur CET appareil est effacé. Les '
              'amitiés reviendront à la prochaine synchronisation, celles '
              'qui existent encore côté serveur.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Effacer'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await ref.read(proximityControllerProvider.notifier).resetLocalPing();
        } catch (_) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Échec de la remise à zéro.')),
          );
          return;
        }
        messenger.showSnackBar(
          const SnackBar(content: Text('Ping remis à zéro sur cet appareil.')),
        );
      },
    );
  }
}
