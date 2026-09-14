import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/typography.dart';
import 'album_publish_queue.dart';

/// **Le bandeau de publication d'un album**, en tête du profil — la même
/// forme que le bandeau d'envoi des Vibes (`ShareProgressBanner`), pour la
/// même raison : l'utilisateur a déjà rendu la main.
///
/// - **préparation** : « Préparation… 2/5 (40 %) », le rendu des médias ;
/// - **publication** : « Publication… 3/7 », les fichiers déposés ;
/// - **publié** : s'efface seul après un instant ;
/// - **échec** : reste jusqu'au ✕.
///
/// Il observe [albumPublishQueueProvider] et ne décide de rien d'autre. S'il
/// n'y a rien à dire, il n'occupe pas un pixel.
class AlbumPublishBanner extends ConsumerStatefulWidget {
  const AlbumPublishBanner({super.key});

  @override
  ConsumerState<AlbumPublishBanner> createState() => _AlbumPublishBannerState();
}

class _AlbumPublishBannerState extends ConsumerState<AlbumPublishBanner> {
  Timer? _effacement;

  @override
  void dispose() {
    _effacement?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(albumPublishQueueProvider);
    if (state.phase == AlbumPublishPhase.idle) return const SizedBox.shrink();

    // Publié : s'efface seul.
    if (state.phase == AlbumPublishPhase.done && _effacement == null) {
      _effacement = Timer(const Duration(milliseconds: 2200), () {
        _effacement = null;
        if (mounted) ref.read(albumPublishQueueProvider.notifier).dismiss();
      });
    }

    final scheme = Theme.of(context).colorScheme;
    final echec = state.phase == AlbumPublishPhase.failed;
    final fond = echec ? scheme.errorContainer : scheme.inverseSurface;
    final texte = echec ? scheme.onErrorContainer : scheme.onInverseSurface;
    final avancement = switch (state.phase) {
      AlbumPublishPhase.rendering when state.total > 0 =>
        (state.done + state.progress) / state.total,
      AlbumPublishPhase.uploading when state.total > 0 =>
        state.done / state.total,
      _ => null,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        NeoSpace.sm,
        NeoSpace.md,
        0,
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
                  if (state.isBusy)
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
                      echec ? Icons.error_outline : Icons.check_circle,
                      size: 16,
                      color: texte,
                    ),
                  const SizedBox(width: NeoSpace.sm),
                  Expanded(
                    child: Text(
                      state.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: texte, fontSize: 13),
                    ),
                  ),
                  if (!state.isBusy)
                    IconButton(
                      icon: Icon(Icons.close, size: 18, color: texte),
                      tooltip: 'Fermer',
                      onPressed: () => ref
                          .read(albumPublishQueueProvider.notifier)
                          .dismiss(),
                    ),
                ],
              ),
              if (avancement != null)
                Padding(
                  padding: const EdgeInsets.only(top: NeoSpace.xs),
                  child: LinearProgressIndicator(
                    value: avancement,
                    minHeight: 3,
                    color: texte,
                    backgroundColor: texte.withValues(alpha: 0.2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
