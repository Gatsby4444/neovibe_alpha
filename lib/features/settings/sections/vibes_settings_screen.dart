import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../../cards/saved_items_screen.dart';
import '../settings_common.dart';
import '../storage_screen.dart';

/// Tout ce qui touche aux Vibes : gestes, défauts d'envoi, et où elles vivent.
class VibesSettingsScreen extends ConsumerWidget {
  const VibesSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vibes')),
      body: ListView(
        children: [
          const SettingsHeader('Gestes'),
          SwitchListTile(
            title: const Text('Inverser le sens de retournement'),
            subtitle: const Text(
              'Change le sens dans lequel le swipe retourne une Vibe',
            ),
            value: ref.watch(flipDirectionInvertedProvider),
            onChanged: (v) =>
                ref.read(flipDirectionInvertedProvider.notifier).set(v),
          ),
          const Divider(),
          const SettingsHeader('Défauts d\'envoi'),
          const SettingsNote(
            'Appliqués aux nouvelles Vibes. Modifiables Vibe par Vibe au '
            'moment de l\'envoi.',
          ),
          const _CardDefaultsSection(),
          const Divider(),
          const SettingsHeader('Ce que voient les autres'),
          const _Divulgation(),
          const Divider(),
          const SettingsHeader('Où vivent mes Vibes'),
          ListTile(
            leading: const Icon(Icons.bookmark),
            title: const Text('Enregistrements'),
            subtitle: const Text(
              'Ta bibliothèque privée — visible de toi seul',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SavedItemsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Stockage des Vibes'),
            subtitle: const Text('Copies locales, cache et espace alloué'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const StorageScreen())),
          ),
        ],
      ),
    );
  }
}

/// Défauts appliqués aux nouvelles Cards (modifiables card par card à l'envoi).
class _CardDefaultsSection extends ConsumerWidget {
  const _CardDefaultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(defaultMaxViewsProvider);
    final duration = ref.watch(defaultViewDurationProvider);
    final unlimited = duration == DefaultViewDuration.unlimited;
    final durationSlider = unlimited ? 21 : duration;

    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text('Visionnages par défaut : $views'),
          subtitle: Slider(
            value: views.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            label: '$views',
            onChanged: (v) =>
                ref.read(defaultMaxViewsProvider.notifier).set(v.round()),
          ),
        ),
        ListTile(
          dense: true,
          title: Text(
            unlimited
                ? 'Durée de lecture par défaut : illimitée'
                : 'Durée de lecture par défaut : $duration s',
          ),
          subtitle: Slider(
            value: durationSlider.toDouble(),
            min: 1,
            max: 21,
            divisions: 20,
            label: unlimited ? '∞' : '$duration s',
            onChanged: (v) {
              final rounded = v.round();
              ref
                  .read(defaultViewDurationProvider.notifier)
                  .set(rounded == 21 ? DefaultViewDuration.unlimited : rounded);
            },
          ),
        ),
      ],
    );
  }
}

/// Règles de confidentialité des Cards, énoncées noir sur blanc (consigne Jay).
class _Divulgation extends StatelessWidget {
  const _Divulgation();

  @override
  Widget build(BuildContext context) => const SettingsNote(
    'Dans les chats, tes Vibes apparaissent comme des containers '
    'cliquables et se voient un nombre de fois et une durée limités '
    '(que tu choisis). Le container reste 24 h et le replay ne se fait '
    'qu\'avec ton accord. Envoyée à une seule personne sans être publiée, '
    'une Vibe devient une One of One : exclusive, à jamais. En '
    'bibliothèque, la lecture est illimitée.',
  );
}
