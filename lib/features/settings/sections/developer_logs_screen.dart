import 'package:flutter/material.dart';

import '../app_log_screen.dart';
import '../camera_log_screen.dart';
import '../settings_common.dart';
import '../video_timing_screen.dart';

/// Les traces et les mesures, réunies.
///
/// Chacune a son écran et son bouton de copie ; le bouton **« Tout copier »**
/// du dossier Développeur les rassemble en un seul bloc — c'est celui à
/// utiliser pour un rapport, celui-ci pour regarder de près.
class DeveloperLogsScreen extends StatelessWidget {
  const DeveloperLogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Journaux et mesures')),
      body: ListView(
        children: const [
          SettingsNote(
            'Pour m\'envoyer un rapport complet, préfère « Tout copier pour '
            'diagnostic » à la racine du dossier Développeur : il rassemble '
            'ces trois sources et l\'appareil en une fois.',
          ),
          SettingsCategoryTile(
            icon: Icons.timer_outlined,
            title: 'Lecture vidéo — temps d\'ouverture',
            subtitle:
                'Combien de temps entre la demande et la première image, '
                'étape par étape. Cible : 300 ms en cache, 1 s à froid.',
            builder: _timing,
          ),
          SettingsCategoryTile(
            icon: Icons.receipt_long,
            title: 'Journal caméra',
            subtitle:
                'Trace détaillée (natif + Dart), conservée même après un '
                'crash.',
            builder: _camera,
          ),
          SettingsCategoryTile(
            icon: Icons.article_outlined,
            title: 'Journal de l\'app',
            subtitle:
                'Tout le reste : gestes, réactions de l\'app, échanges '
                'serveur et erreurs. Filtrable, conservé après un crash.',
            builder: _app,
          ),
        ],
      ),
    );
  }

  static Widget _timing(BuildContext _) => const VideoTimingScreen();
  static Widget _camera(BuildContext _) => const CameraLogScreen();
  static Widget _app(BuildContext _) => const AppLogScreen();
}
