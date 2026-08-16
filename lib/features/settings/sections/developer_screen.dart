import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/diagnostics/diagnostic_bundle.dart';
import '../settings_common.dart';
import 'developer_flags_screen.dart';
import 'developer_logs_screen.dart';
import 'day_cycle_preview_screen.dart';
import 'developer_tools_screen.dart';
import '../../proximity/proximity_diagnostic_screen.dart';
import 'developer_update_screen.dart';

/// Le dossier **Développeur** — tout ce qui doit disparaître avant la prod.
///
/// ### Pourquoi il est isolé
///
/// Ces réglages étaient jusqu'au 2026-08-13 mêlés à ceux de l'utilisateur, à la
/// suite, séparés par un simple trait. C'est un risque concret et déjà consigné
/// (`RAPPELS.md`, avant-prod #4 et #8) : **un interrupteur de test perdu au
/// milieu des vrais réglages est un interrupteur qu'on oublie de retirer.**
/// Rassemblé sous une seule porte, le retrait devient une opération unique et
/// vérifiable — on supprime ce dossier, et il ne reste rien.
class DeveloperScreen extends StatelessWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Développeur')),
      body: ListView(
        children: [
          const SettingsNote(
            'Mode test. Tout ce qui se trouve dans ce dossier sera retiré '
            'avant la mise en production.',
          ),
          const _CopyEverythingTile(),
          const SettingsCategoryTile(
            icon: Icons.system_update,
            title: 'Mise à jour et rapports',
            subtitle:
                'Installer la dernière release, et envoyer le diagnostic au '
                'serveur au lieu de le copier',
            builder: _update,
          ),
          const Divider(),
          const SettingsCategoryTile(
            icon: Icons.toggle_on_outlined,
            title: 'Interrupteurs de test',
            subtitle:
                'Anti-capture, diagnostic caméra, TTL visible, vue simple '
                'Oneshot',
            builder: _flags,
          ),
          const SettingsCategoryTile(
            icon: Icons.receipt_long,
            title: 'Journaux et mesures',
            subtitle:
                'Journal caméra, journal de l\'app, temps d\'ouverture '
                'vidéo',
            builder: _logs,
          ),
          const SettingsCategoryTile(
            icon: Icons.science_outlined,
            title: 'Outils',
            subtitle: 'Aperçu GPU, déclenchement BeReal',
            builder: _tools,
          ),
          const SettingsCategoryTile(
            icon: Icons.wifi_tethering,
            title: 'Diagnostic proximité',
            subtitle:
                'Les DEUX sens de la radio séparément, et chaque appareil vu '
                'avec son adresse',
            builder: _proximity,
          ),
          const SettingsCategoryTile(
            icon: Icons.wb_twilight,
            title: 'Cycle de 24 h — aperçu',
            subtitle:
                'Le fond du thème NeoVibe heure par heure. Curseur pour '
                'juger les couleurs, lecture pour juger la vitesse.',
            builder: _dayCycle,
          ),
        ],
      ),
    );
  }

  // Des fonctions nommées, et non des lambdas : un `const` sur la tuile exige
  // un constructeur constant, donc des références de fonction constantes.
  static Widget _flags(BuildContext _) => const DeveloperFlagsScreen();
  static Widget _logs(BuildContext _) => const DeveloperLogsScreen();
  static Widget _tools(BuildContext _) => const DeveloperToolsScreen();
  static Widget _dayCycle(BuildContext _) => const DayCyclePreviewScreen();
  static Widget _update(BuildContext _) => const DeveloperUpdateScreen();
  static Widget _proximity(BuildContext _) => const ProximityDiagnosticScreen();
}

/// Le bouton que Jay a demandé : **tout**, en une fois, prêt à être renvoyé.
///
/// Relever les traces une par une, c'est quatre écrans et autant d'occasions
/// d'en oublier une — ou de coller la mauvaise. Ici, un seul geste rassemble
/// l'appareil, la version installée, les mesures vidéo, le journal caméra et
/// le journal de l'app.
class _CopyEverythingTile extends StatefulWidget {
  const _CopyEverythingTile();

  @override
  State<_CopyEverythingTile> createState() => _CopyEverythingTileState();
}

class _CopyEverythingTileState extends State<_CopyEverythingTile> {
  var _busy = false;

  Future<void> _copy() async {
    setState(() => _busy = true);
    String text;
    try {
      text = await DiagnosticBundle.build();
    } catch (e) {
      // Même en échec, on copie de quoi comprendre l'échec.
      text = 'La collecte a échoué : $e';
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _busy = false);
    final lines = '\n'.allMatches(text).length + 1;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Diagnostic copié — $lines lignes')));
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: _busy
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.copy_all),
    title: const Text('Tout copier pour diagnostic'),
    subtitle: const Text(
      'Appareil, version, mesures vidéo, journal caméra et journal de l\'app '
      '— en un seul bloc à coller.',
    ),
    onTap: _busy ? null : _copy,
  );
}
