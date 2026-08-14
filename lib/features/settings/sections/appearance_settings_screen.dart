import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../../../core/theme.dart';
import '../../cards/camera_controls.dart';
import '../settings_common.dart';

/// Apparence et démarrage : ce que l'app montre, et par où elle s'ouvre.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final light = ref.watch(lightThemeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Apparence et démarrage')),
      body: ListView(
        children: [
          const SettingsHeader('Thème'),
          SwitchListTile(
            secondary: Icon(light ? Icons.light_mode : Icons.dark_mode),
            title: const Text('Thème clair'),
            subtitle: const Text(
              'La caméra et la visionneuse de Vibes restent sombres : c\'est '
              'le contenu qui porte la lumière.',
            ),
            value: light,
            onChanged: (v) => ref.read(lightThemeProvider.notifier).set(v),
          ),
          const Divider(),
          const SettingsHeader('Boutons de la caméra'),
          const _CameraStyleSection(),
          const Divider(),
          const SettingsHeader('Démarrage'),
          const _StartupTabSection(),
        ],
      ),
    );
  }
}

/// Les quatre directions artistiques proposées pour les contrôles de la
/// capture (Jay, 2026-08-14). Réglage de **comparaison** : il disparaîtra une
/// fois la direction tranchée.
///
/// Chaque entrée montre un aperçu réel du bouton — un carré de couleur ne
/// permettrait pas de choisir, et redescendre dans la caméra à chaque essai
/// ferait perdre le fil de la comparaison.
class _CameraStyleSection extends ConsumerWidget {
  const _CameraStyleSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(captureButtonStyleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsNote(
          'Le style des boutons de l\'écran de capture. Change tout de suite : '
          'ouvre la caméra pour juger sur une vraie image.',
        ),
        for (final style in CameraButtonStyle.values)
          ListTile(
            leading: Icon(
              current == style.index
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: current == style.index
                  ? NeoTheme.accentPink
                  : context.faint,
            ),
            title: Text(style.label),
            subtitle: Text(style.description),
            isThreeLine: true,
            // L'aperçu est posé sur un fond sombre : les contrôles vivent sur
            // l'image caméra, les juger sur le fond clair des réglages
            // donnerait une impression fausse.
            trailing: _StylePreview(style: style),
            onTap: () =>
                ref.read(captureButtonStyleProvider.notifier).set(style.index),
          ),
      ],
    );
  }
}

class _StylePreview extends StatelessWidget {
  const _StylePreview({required this.style});

  final CameraButtonStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 74,
      height: 74,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Un gris moyen plutôt que du noir : c'est le pire cas de lisibilité,
        // celui où un contour blanc et un disque sombre se valent presque.
        color: const Color(0xFF6A6A6A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: CameraRail(
        style: style,
        children: const [CameraButton(icon: Icon(Icons.bolt))],
      ),
    );
  }
}

/// Onglet sur lequel l'app s'ouvre (consigne Jay 2026-08-01). L'onglet Card
/// n'est pas proposé : c'est un bouton de capture, pas une destination.
/// Le changement ne prend effet qu'au lancement suivant — l'app ne saute pas
/// d'onglet pendant qu'on règle.
class _StartupTabSection extends ConsumerWidget {
  const _StartupTabSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(startupTabProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsNote(
          'L\'onglet ouvert au lancement de NeoVibe. Prend effet au prochain '
          'démarrage.',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Wrap(
            spacing: 8,
            children: [
              for (final tab in StartupTab.values)
                ChoiceChip(
                  label: Text(tab.label),
                  selected: tab == current,
                  showCheckmark: false,
                  selectedColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.25),
                  onSelected: (_) =>
                      ref.read(startupTabProvider.notifier).set(tab),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
