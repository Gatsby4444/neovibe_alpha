import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../core/prefs.dart';
import '../../../core/typography.dart';
import '../settings_common.dart';

/// Apparence et démarrage : ce que l'app montre, et par où elle s'ouvre.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(themeIdentityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Apparence et démarrage')),
      body: ListView(
        children: [
          const SettingsHeader('Thème'),
          // Cinq identités MUTUELLEMENT EXCLUSIVES (Jay, 2026-08-29). Aurore et
          // Sable suivent le jour et la nuit du téléphone ; les trois autres
          // sont des choix fermes. C'est ce découpage qui évite qu'un réglage
          // horaire se batte avec un interrupteur clair/sombre.
          RadioGroup<NeoIdentity>(
            groupValue: identity,
            onChanged: (v) => v == null
                ? null
                : ref.read(themeIdentityProvider.notifier).set(v),
            child: Column(
              children: [
                for (final t in NeoIdentity.values)
                  RadioListTile<NeoIdentity>(
                    value: t,
                    // L'aperçu vaut mieux qu'une icône : on choisit une couleur,
                    // donc on doit la voir avant de la choisir.
                    secondary: _Apercu(identity: t),
                    title: Text(t.label),
                    subtitle: Text(
                      t.suitLeSysteme
                          ? '${t.description} · suit le jour et la nuit'
                          : t.description,
                    ),
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

/// Trois pastilles : le fond, la surface posée dessus, et la couleur d'action.
///
/// ⚠️ **Un aperçu se construit depuis la palette, jamais depuis des couleurs
/// recopiées.** Recopiées, elles cesseraient de dire la vérité au premier
/// changement de palette — et un aperçu faux est pire que pas d'aperçu.
class _Apercu extends StatelessWidget {
  const _Apercu({required this.identity});

  final NeoIdentity identity;

  @override
  Widget build(BuildContext context) {
    // On montre la palette de JOUR : c'est celle qu'on a sous les yeux en
    // réglant, et montrer la nuit ici ferait douter du choix.
    final p = identity.palette(Brightness.light);
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.ground,
                borderRadius: BorderRadius.circular(NeoRadius.sm),
                border: Border.all(color: p.line),
              ),
            ),
          ),
          Positioned(
            left: 6,
            top: 6,
            right: 14,
            bottom: 14,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: p.line),
              ),
            ),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                gradient: identity.fondDuCycle ? null : p.signatureCourte,
                color: identity.fondDuCycle ? p.action : null,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
