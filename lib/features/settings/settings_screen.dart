import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'sections/appearance_settings_screen.dart';
import 'sections/camera_settings_screen.dart';
import 'sections/developer_screen.dart';
import 'sections/privacy_settings_screen.dart';
import 'sections/sharing_settings_screen.dart';
import 'sections/vibes_settings_screen.dart';
import 'settings_common.dart';

/// L'entrée des réglages : **des dossiers, pas une liste**.
///
/// ### Ce que ça remplace
///
/// Jusqu'au 2026-08-13, tout tenait sur un seul écran de près de 300 lignes —
/// le thème, la caméra, la visibilité de la bibliothèque et les interrupteurs
/// de développement se suivaient, séparés par de simples traits. Demande de
/// Jay : « réorganise les paramètres en plusieurs sections et sous-sections,
/// pas tout mélangé dans la même interface mais des dossiers et sous-dossiers,
/// mets les paramètres développeurs dans un dossier développeur ».
///
/// Le rangement a un effet au-delà du confort : **le dossier Développeur se
/// retire d'un bloc** avant la prod, au lieu d'aller chercher une à une des
/// entrées dispersées (`RAPPELS.md`, avant-prod #4 et #8).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(supabaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        children: [
          const SettingsCategoryTile(
            icon: Icons.palette_outlined,
            title: 'Apparence et démarrage',
            subtitle: 'Thème, onglet d\'ouverture',
            builder: _appearance,
          ),
          const SettingsCategoryTile(
            icon: Icons.auto_awesome,
            title: 'Vibes',
            subtitle: 'Gestes, défauts d\'envoi, enregistrements et stockage',
            builder: _vibes,
          ),
          const SettingsCategoryTile(
            icon: Icons.photo_camera_outlined,
            title: 'Caméra',
            subtitle: 'Miroir de la frontale',
            builder: _camera,
          ),
          const SettingsCategoryTile(
            icon: Icons.visibility_outlined,
            title: 'Partage et visibilité',
            subtitle: 'Qui voit tes stories et ta bibliothèque',
            builder: _sharing,
          ),
          const SettingsCategoryTile(
            icon: Icons.shield_outlined,
            title: 'Sécurité et confidentialité',
            subtitle: 'Personnes bloquées, waves en temps réel',
            builder: _privacy,
          ),
          const Divider(),
          const SettingsCategoryTile(
            icon: Icons.construction,
            title: 'Développeur',
            subtitle: 'Mode test — sera retiré avant la production',
            builder: _developer,
          ),
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

  // Des fonctions nommées : une tuile `const` exige des références constantes.
  static Widget _appearance(BuildContext _) => const AppearanceSettingsScreen();
  static Widget _vibes(BuildContext _) => const VibesSettingsScreen();
  static Widget _camera(BuildContext _) => const CameraSettingsScreen();
  static Widget _sharing(BuildContext _) => const SharingSettingsScreen();
  static Widget _privacy(BuildContext _) => const PrivacySettingsScreen();
  static Widget _developer(BuildContext _) => const DeveloperScreen();
}
