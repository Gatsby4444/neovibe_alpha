import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../settings_common.dart';

/// Apparence et démarrage : ce que l'app montre, et par où elle s'ouvre.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(themeChoiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Apparence et démarrage')),
      body: ListView(
        children: [
          const SettingsHeader('Thème'),
          // Trois thèmes MUTUELLEMENT EXCLUSIFS (décision de Jay 2026-08-14).
          // C'est ce découpage qui évite qu'un réglage horaire se batte avec un
          // interrupteur clair/sombre : l'heure est une propriété du seul thème
          // NeoVibe, donc choisir clair ou sombre suffit à l'éteindre.
          RadioGroup<NeoThemeChoice>(
            groupValue: choice,
            onChanged: (v) => v == null
                ? null
                : ref.read(themeChoiceProvider.notifier).set(v),
            child: Column(
              children: [
                for (final t in NeoThemeChoice.values)
                  RadioListTile<NeoThemeChoice>(
                    value: t,
                    secondary: Icon(switch (t) {
                      NeoThemeChoice.neovibe => Icons.gradient,
                      NeoThemeChoice.light => Icons.light_mode,
                      NeoThemeChoice.dark => Icons.dark_mode,
                    }),
                    title: Text(t.label),
                    subtitle: Text(switch (t) {
                      NeoThemeChoice.neovibe =>
                        'Un dégradé qui suit l\'heure, du matin à la nuit. '
                            'Le changement est trop lent pour se voir.',
                      NeoThemeChoice.light => 'Blanc, fixe.',
                      NeoThemeChoice.dark => 'Noir, fixe.',
                    }),
                  ),
              ],
            ),
          ),
          const SettingsNote(
            'La caméra et la visionneuse de Vibes restent sombres quel que soit '
            'le thème : c\'est le contenu qui porte la lumière.',
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
