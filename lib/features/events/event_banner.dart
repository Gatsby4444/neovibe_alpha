import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/typography.dart';
import 'event_screen.dart';
import 'events_providers.dart';

/// **Le mode événement, vu depuis le Cercle.** Rien tant que je ne suis dans
/// aucun événement ; un bandeau vers l'événement dès que j'y suis.
///
/// Consigne de Jay (2026-09-12) : *« le mode événement n'apparaît que si tu
/// rejoins un événement, de sorte à ne pas polluer l'app avec des choses que
/// l'utilisateur n'utilise pas tout le temps »*.
///
/// ⚠️ Ce widget ne lit que [currentEventIdProvider] et [eventByIdProvider] :
/// il se reconstruit quand j'entre ou je sors, et quand CET événement
/// change — pas à chaque mouvement de quelqu'un d'autre.
class EventBanner extends ConsumerWidget {
  const EventBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(currentEventIdProvider);
    if (id == null) return const SizedBox.shrink();
    final event = ref.watch(eventByIdProvider(id));
    final p = context.palette;
    final n = event?.presentCount ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: p.action.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(NeoRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => EventScreen(eventId: id))),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NeoSpace.lg,
              vertical: NeoSpace.md,
            ),
            child: Row(
              children: [
                Icon(Icons.celebration, color: p.action, size: 20),
                const SizedBox(width: NeoSpace.md),
                Expanded(
                  child: Text(
                    event == null
                        ? 'Tu es dans un événement'
                        : 'Tu es à ${event.title} · $n présent${n > 1 ? 's' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
