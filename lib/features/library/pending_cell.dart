import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/publish/publish_bridge.dart';
import 'pending_publications.dart';

/// **Une publication en cours d'envoi, dans la grille** — à la place où elle
/// apparaîtra : sa couverture, assombrie, avec son avancement. Comme
/// Instagram (Jay, 2026-09-19).
///
/// - en cours : l'anneau tourne, ou avance avec la préparation / l'envoi ;
/// - **échec** : un point d'exclamation ; un appui propose de réessayer ou
///   d'abandonner — rien ne se réessaie tout seul ;
/// - publié : la case reste un instant, le temps que la vraie publication
///   arrive dans la liste (voir `PendingPublications.seen`).
class PendingCell extends ConsumerWidget {
  const PendingCell({super.key, required this.item, required this.ratio});

  final PendingPublication item;
  final double ratio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cover = item.cover;
    final failed = item.isFailed;
    return GestureDetector(
      onTap: failed ? () => _echec(context, ref) : null,
      child: AspectRatio(
        aspectRatio: ratio,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            border: Border.all(
              color: failed ? scheme.error : scheme.outlineVariant,
              width: 1.6,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover != null && File(cover).existsSync())
                Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 400),
              ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
              Center(
                child: failed
                    ? const Icon(
                        Icons.error_outline,
                        color: Colors.white,
                        size: 32,
                      )
                    : SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          // L'anneau n'avance que sur une mesure : rien de
                          // mesurable pendant l'inscription → il tourne.
                          value:
                              item.phase == 'preparing' ||
                                  item.phase == 'uploading'
                              ? item.progress.clamp(0.02, 1.0)
                              : null,
                          strokeWidth: 3,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 6,
                child: Text(
                  item.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _echec(BuildContext context, WidgetRef ref) async {
    final choix = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Publication échouée'),
        content: Text(item.error ?? 'Une erreur est survenue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'abandon'),
            child: const Text('Abandonner'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'retry'),
            child: const Text('Réessayer'),
          ),
        ],
      ),
    );
    final notifier = ref.read(pendingPublicationsProvider.notifier);
    switch (choix) {
      case 'retry':
        await notifier.retry(item.id);
      case 'abandon':
        await notifier.abandon(item.id);
    }
  }
}
