import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs.dart';

/// **Les interrupteurs de test de la carte** (DÉVELOPPEUR, 2026-09-26) —
/// une seule pièce, posée à deux endroits : la roue de réglages de la carte
/// (Jay : *« ajoute les interrupteurs de test directement accessibles depuis
/// la map »*) et Réglages › Développeur › Interrupteurs. Deux endroits, un
/// seul état : les réglages vivent dans les préférences, pas ici.
///
/// ⚠️ À retirer avec la section Développeur, une fois les choix tranchés.
class MapTestSettings extends ConsumerWidget {
  const MapTestSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          title: const Text('Inclinaison : les deux doigts doivent bouger'),
          subtitle: const Text(
            "Deux doigts qui vont dans la même direction inclinent la vue ; "
            "un doigt fixe et l'autre qui bouge, non.",
          ),
          value: ref.watch(devTiltBothFingersProvider),
          onChanged: (v) =>
              ref.read(devTiltBothFingersProvider.notifier).set(v),
        ),
        SwitchListTile(
          title: const Text('Objets 3D (bâtiments, arbres, ombres)'),
          subtitle: const Text(
            'Éteins-les pour voir si la carte devient plus fluide : ce sont '
            'eux qui coûtent le plus à dessiner.',
          ),
          value: ref.watch(devMap3dProvider),
          onChanged: (v) => ref.read(devMap3dProvider.notifier).set(v),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Mode d'affichage (la carte se recrée)",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        RadioGroup<MapHosting>(
          groupValue: ref.watch(devMapHostingProvider).value,
          onChanged: (v) {
            if (v != null) ref.read(devMapHostingProvider.notifier).set(v);
          },
          child: Column(
            children: [
              for (final m in MapHosting.values)
                RadioListTile<MapHosting>(
                  title: Text(m.label),
                  subtitle: Text(m.detail),
                  value: m,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
