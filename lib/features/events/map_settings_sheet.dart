import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs.dart';
import '../../core/widgets/avatar.dart';
import '../connections/connections_repository.dart';
import '../map/friends_map.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **Les réglages de la carte, pour l'utilisateur** — derrière la roue de
/// la carte (Jay, 2026-09-26 : *« on garde le bouton réglages, il servira
/// pour les paramétrages utilisateurs de la carte »*). Les réglages vivent
/// dans les préférences, pas ici : la roue ne fait que les montrer.
class MapSettingsSheet extends ConsumerWidget {
  const MapSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Réglages de la carte',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        // Ma position, vue par mes amis — éteinte par défaut (Jay).
        SwitchListTile(
          title: const Text('Partager ma position avec mes amis'),
          subtitle: const Text(
            "Mes amis me voient sur leur carte, avec l'heure du relevé. "
            "Mise à jour toutes les 10 s quand j'ai la carte ouverte, "
            "toutes les 30 min sinon. L'arrêter efface ma position.",
          ),
          value: ref.watch(locationSharingProvider).value ?? false,
          onChanged: ref.watch(locationSharingProvider).isLoading
              ? null
              : (v) => ref.read(locationSharingProvider.notifier).set(v),
        ),
        if (ref.watch(locationSharingProvider).value ?? false)
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('Cacher ma position à…'),
            subtitle: Text(
              switch ((ref.watch(locationHiddenFromProvider).value ?? const {})
                  .length) {
                0 => 'Tous mes amis me voient',
                1 => '1 ami ne me voit pas',
                final n => '$n amis ne me voient pas',
              },
            ),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => const _CacherA(),
            ),
          ),
        const Divider(),
        _RayonSoirees(
          km: ref.watch(mapEventsRadiusKmProvider),
          regles: ref.watch(mapEventRulesProvider).value ?? MapEventRules.repli,
          onChanged: (km) =>
              ref.read(mapEventsRadiusKmProvider.notifier).set(km),
        ),
        SwitchListTile(
          title: const Text('Vibes publiques autour de moi'),
          subtitle: const Text(
            'Les plus aimées et les plus récentes, dans 3 km — seulement '
            'celles que leurs auteurs ont choisi de situer.',
          ),
          value: ref.watch(mapShowVibesProvider),
          onChanged: (v) => ref.read(mapShowVibesProvider.notifier).set(v),
        ),
        SwitchListTile(
          title: const Text('Bâtiments en 3D'),
          subtitle: const Text(
            'Plus joli en vue inclinée ; la carte est un peu moins fluide.',
          ),
          value: ref.watch(mapBuildings3dProvider),
          onChanged: (v) => ref.read(mapBuildings3dProvider.notifier).set(v),
        ),
      ],
    );
  }
}

/// Le curseur « voir les soirées jusqu'à … km », borné par les règles du
/// serveur (qui borne de toute façon : l'écran ne fait que l'annoncer).
class _RayonSoirees extends StatefulWidget {
  const _RayonSoirees({
    required this.km,
    required this.regles,
    required this.onChanged,
  });

  final int km;
  final MapEventRules regles;
  final ValueChanged<int> onChanged;

  @override
  State<_RayonSoirees> createState() => _RayonSoireesState();
}

class _RayonSoireesState extends State<_RayonSoirees> {
  /// La valeur pendant qu'on fait glisser : enregistrée au lâcher seulement
  /// (sinon chaque cran relancerait la recherche des soirées).
  double? _glisse;

  @override
  Widget build(BuildContext context) {
    final min = widget.regles.radiusMinKm.toDouble();
    final max = widget.regles.radiusMaxKm.toDouble();
    final valeur = (_glisse ?? widget.km.toDouble()).clamp(min, max);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Voir les soirées jusqu\'à ${valeur.round()} km',
            style: const TextStyle(fontSize: 16),
          ),
          Slider(
            value: valeur,
            min: min,
            max: max,
            divisions: (max - min).round().clamp(1, 1000),
            label: '${valeur.round()} km',
            onChanged: (v) => setState(() => _glisse = v),
            onChangeEnd: (v) {
              setState(() => _glisse = null);
              widget.onChanged(v.round());
            },
          ),
        ],
      ),
    );
  }
}

/// **Cacher ma position à certains amis** — une case par ami.
class _CacherA extends ConsumerWidget {
  const _CacherA();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amis = ref.watch(friendProfilesProvider).value ?? const {};
    final caches = ref.watch(locationHiddenFromProvider).value ?? const {};
    final liste = amis.values.toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Cocher les amis qui ne doivent PAS voir ma position',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final ami in liste)
                    CheckboxListTile(
                      secondary: Avatar(stored: ami.avatarUrl, radius: 18),
                      title: Text(ami.displayName),
                      value: caches.contains(ami.id),
                      onChanged: (v) => ref
                          .read(locationHiddenFromProvider.notifier)
                          .set(ami.id, v ?? false),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
