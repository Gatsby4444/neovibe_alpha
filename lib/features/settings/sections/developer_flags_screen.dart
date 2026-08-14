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
          const SettingsHeader('Caméra'),
          // PILOTE DU 2026-08-14 — le rail en verre de l'écran de capture.
          //
          // Cet interrupteur existe pour MESURER, pas pour offrir un choix à
          // l'utilisateur : il faut pouvoir comparer deux relevés de coût sur
          // la MÊME scène. Une fois la mesure faite, le défaut est tranché et
          // cet interrupteur disparaît avec la section Développeur.
          SwitchListTile(
            title: const Text('Verre dépoli sur le rail de capture'),
            subtitle: const Text(
              'Activé : vrai flou de l\'aperçu (BackdropFilter). Désactivé : '
              'repli économique, sans lecture du tampon d\'affichage.\n'
              'Pour mesurer : ouvre la capture, laisse tourner ~20 s dans '
              'chaque position SANS changer de scène, puis Développeur → '
              '« Tout copier pour diagnostic ».',
            ),
            value: ref.watch(captureGlassFullProvider),
            onChanged: (v) =>
                ref.read(captureGlassFullProvider.notifier).set(v),
          ),
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
