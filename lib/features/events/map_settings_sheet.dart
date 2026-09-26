import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs.dart';
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
        _RayonSoirees(
          km: ref.watch(mapEventsRadiusKmProvider),
          regles: ref.watch(mapEventRulesProvider).value ?? MapEventRules.repli,
          onChanged: (km) =>
              ref.read(mapEventsRadiusKmProvider.notifier).set(km),
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
