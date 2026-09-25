import 'package:flutter/material.dart';

import '../../core/models/event.dart';
import '../../core/theme.dart';

/// **Choisir la taille d'une soirée** (Jay, 2026-09-25) — la même pièce à la
/// création et dans les réglages. Trois tailles, jamais une autre : le
/// serveur refuse le reste (`private.event_size_radius`, `set_event_size`).
class EventSizePicker extends StatelessWidget {
  const EventSizePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final EventSize value;

  /// Nul = figé (pendant un envoi).
  final ValueChanged<EventSize>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Taille de la soirée',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        SegmentedButton<EventSize>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: EventSize.bar, label: Text('Bar')),
            ButtonSegment(value: EventSize.grand, label: Text('Grand lieu')),
            ButtonSegment(value: EventSize.pleinAir, label: Text('Plein air')),
          ],
          selected: {value},
          onSelectionChanged: onChanged == null
              ? null
              : (s) => onChanged!(s.first),
        ),
        const SizedBox(height: 4),
        Text(
          "${value.detail}. On en sort en s'éloignant à "
          '${value.radiusM * 2} m.',
          style: TextStyle(color: context.muted, fontSize: 12),
        ),
      ],
    );
  }
}
