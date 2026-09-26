import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../../cards/native_camera.dart';
import '../settings_common.dart';

/// Les interrupteurs de test.
///
/// ⚠️ **À retirer avant la prod** — et l'anti-capture doit repasser à ACTIF par
/// défaut au même moment (`RAPPELS.md`, avant-prod #6).
class DeveloperFlagsScreen extends ConsumerWidget {
  const DeveloperFlagsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Interrupteurs de test')),
      body: ListView(
        children: [
          const SettingsHeader('Sécurité'),
          SwitchListTile(
            title: const Text('Anti-capture (FLAG_SECURE)'),
            subtitle: const Text(
              'DÉSACTIVÉ pendant le dev : les captures d\'écran sont '
              'possibles. Active pour tester le blocage des screenshots et '
              'du partage d\'écran. À réactiver par défaut avant la prod.',
            ),
            value: ref.watch(devSecureEnabledProvider),
            onChanged: (v) async {
              await ref.read(devSecureEnabledProvider.notifier).set(v);
              await NativeCameraController.setSecure(v);
            },
          ),
          const Divider(),
          const SettingsHeader('Affichage'),
          SwitchListTile(
            title: const Text(
              'Afficher « disparaît dans … » sous les messages',
            ),
            subtitle: const Text(
              'Retiré de l\'affichage courant : l\'éphémère est une règle du '
              'produit, pas un chronomètre à surveiller message par message. '
              'Active pour vérifier le TTL en test.',
            ),
            value: ref.watch(devShowExpiryProvider),
            onChanged: (v) => ref.read(devShowExpiryProvider.notifier).set(v),
          ),
          const Divider(),
          const SettingsHeader('Carte'),
          // Comparer la fluidité sur le téléphone (2026-09-26) : la carte se
          // rouvre avec le mode choisi.
          RadioGroup<MapHosting>(
            groupValue: ref.watch(devMapHostingProvider).value,
            onChanged: (v) {
              if (v != null) ref.read(devMapHostingProvider.notifier).set(v);
            },
            child: Column(
              children: [
                for (final m in MapHosting.values)
                  RadioListTile<MapHosting>(
                    title: Text(m.label),
                    subtitle: Text(m.detail),
                    value: m,
                  ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Objets 3D (bâtiments, arbres, ombres)'),
            subtitle: const Text(
              'Éteins-les pour voir si la carte devient plus fluide : ce sont '
              'eux qui coûtent le plus à dessiner.',
            ),
            value: ref.watch(devMap3dProvider),
            onChanged: (v) => ref.read(devMap3dProvider.notifier).set(v),
          ),
          const Divider(),
          const SettingsHeader('Caméra'),
          SwitchListTile(
            title: const Text('Diagnostic caméra sur l\'aperçu'),
            subtitle: const Text(
              'Affiche résolution, rotation et état du double flux — pour '
              'diagnostiquer un aperçu distordu.',
            ),
            value: ref.watch(devCameraHudProvider),
            onChanged: (v) => ref.read(devCameraHudProvider.notifier).set(v),
          ),
          SwitchListTile(
            title: const Text('Forcer la vue simple Oneshot'),
            subtitle: const Text(
              'Le Oneshot ouvre le double flux (les deux caméras) PAR DÉFAUT '
              'pour capturer les deux faces au même instant. Activer cet '
              'interrupteur force la vue simple (une caméra à la fois, prises '
              'séquentielles) — utile si le double flux se comporte mal sur '
              'l\'appareil.',
            ),
            value: ref.watch(devDualOneshotProvider),
            onChanged: (v) => ref.read(devDualOneshotProvider.notifier).set(v),
          ),
        ],
      ),
    );
  }
}
