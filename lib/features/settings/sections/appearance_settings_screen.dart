import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
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
          const SettingsHeader('Démarrage'),
          const _StartupTabSection(),
        ],
      ),
    );
  }
}

/// Onglet sur lequel l'app s'ouvre (consigne Jay 2026-08-01).
///
/// Le changement ne prend effet qu'au lancement suivant — l'app ne saute pas
/// d'onglet pendant qu'on règle.
///
/// ⚠️ **L'ordre des puces vient de `StartupTab.values`**, donc de l'ordre de
/// déclaration de l'enum. Il doit suivre celui de la barre de navigation, et
/// c'est à `prefs.dart` que ça se règle — pas ici.
///
/// *(Le commentaire précédent affirmait que l'onglet Vibe « n'est pas
/// proposé ». C'était faux : il l'est, et `HomeShell` le traite à part en
/// ouvrant la capture par-dessus le Cercle. Corrigé le 2026-08-15.)*
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
