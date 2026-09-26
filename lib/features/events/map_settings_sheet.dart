import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs.dart';

/// **Les réglages de la carte, pour l'utilisateur** — derrière la roue de
/// la carte (Jay, 2026-09-26 : *« on garde le bouton réglages, il servira
/// pour les paramétrages utilisateurs de la carte »*). Les réglages vivent
/// dans les préférences, pas ici.
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
