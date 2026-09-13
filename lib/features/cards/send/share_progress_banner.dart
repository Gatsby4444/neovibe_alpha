import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/typography.dart';
import 'send_common.dart';
import 'share_queue.dart';

/// **Le bandeau d'envoi** — ce que l'utilisateur voit de la file, pendant
/// qu'il est déjà revenu à la caméra (plan §2.5).
///
/// Trois états, un par travail :
///
/// - **en cours** : « Envoi… 1/3 », une barre qui avance ;
/// - **envoyé** : « Envoyé ✓ », qui s'efface seul après un instant ;
/// - **échec** : nomme ce qui n'est pas parti, avec **Réessayer** pour cette
///   destination seule — jamais « tout renvoyer » — et ✕ pour ranger.
///
/// Il observe [shareQueueProvider] et ne décide de rien d'autre. Posé en bas
/// de la caméra et du chat ; s'il n'y a rien à dire, il n'occupe pas un pixel.
class ShareProgressBanner extends ConsumerWidget {
  const ShareProgressBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(shareQueueProvider);
    if (jobs.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final j in jobs) _JobBanner(job: j)],
    );
  }
}

class _JobBanner extends ConsumerStatefulWidget {
  const _JobBanner({required this.job});
  final ShareJob job;

  @override
  ConsumerState<_JobBanner> createState() => _JobBannerState();
}

class _JobBannerState extends ConsumerState<_JobBanner> {
  Timer? _effacement;

  @override
  void didUpdateWidget(covariant _JobBanner old) {
    super.didUpdateWidget(old);
    _programmeEffacement();
  }

  @override
  void initState() {
    super.initState();
    _programmeEffacement();
  }

  /// Un travail entièrement parti s'efface seul ; un échec reste jusqu'au ✕.
  void _programmeEffacement() {
    if (!widget.job.toutEstParti || _effacement != null) return;
    _effacement = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) {
        ref.read(shareQueueProvider.notifier).dismiss(widget.job.id);
      }
    });
  }

  @override
  void dispose() {
    _effacement?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final echecs = job.echecs;
    final enCours = !job.finished;

    final Color fond;
    final Color texte;
    if (job.aEchoue) {
      fond = scheme.errorContainer;
      texte = scheme.onErrorContainer;
    } else {
      fond = scheme.inverseSurface;
      texte = scheme.onInverseSurface;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        0,
        NeoSpace.md,
        NeoSpace.sm,
      ),
      child: Material(
        color: fond,
        borderRadius: BorderRadius.circular(NeoRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NeoSpace.md,
            NeoSpace.sm,
            NeoSpace.xs,
            NeoSpace.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (enCours)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: texte,
                      ),
                    )
                  else
                    Icon(
                      job.aEchoue ? Icons.error_outline : Icons.check_circle,
                      size: 16,
                      color: texte,
                    ),
                  const SizedBox(width: NeoSpace.sm),
                  Expanded(
                    child: Text(
                      enCours
                          ? 'Envoi… ${job.done}/${job.total}'
                          : job.aEchoue
                          ? '${job.total - echecs.length}/${job.total} '
                                'envoyé(s) · ${echecs.length} en échec'
                          : 'Envoyé ✓',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: texte,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (job.finished)
                    IconButton(
                      icon: Icon(Icons.close, size: 16, color: texte),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Fermer',
                      onPressed: () =>
                          ref.read(shareQueueProvider.notifier).dismiss(job.id),
                    ),
                ],
              ),
              if (enCours)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: NeoSpace.sm),
                  child: LinearProgressIndicator(
                    value: job.total == 0 ? null : job.done / job.total,
                    minHeight: 3,
                    color: texte,
                    backgroundColor: texte.withValues(alpha: 0.2),
                  ),
                ),
              // Ce qui a échoué, nommé, avec Réessayer pour chacun.
              for (final e in echecs)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${e.label} — ${friendlySendError(e.erreur!)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: texte,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => ref
                            .read(shareQueueProvider.notifier)
                            .retry(job.id, e.cle),
                        style: TextButton.styleFrom(
                          foregroundColor: texte,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
