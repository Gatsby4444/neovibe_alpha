import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../content/moderation.dart';
import 'report_sheet.dart';

/// Le menu « … » d'un contenu d'autrui : signaler, bloquer.
///
/// Il n'apparaît **jamais sur son propre contenu** — on ne se signale pas
/// soi-même, et proposer l'action y serait au mieux du bruit.
///
/// C'est le seul point d'entrée de la modération côté utilisateur, et il est
/// volontairement au même endroit dans les deux visionneuses : quelqu'un qui
/// tombe sur un contenu choquant ne doit pas avoir à chercher.
class ContentOverflowMenu extends ConsumerWidget {
  const ContentOverflowMenu({
    super.key,
    required this.contentId,
    required this.authorId,
    this.authorName,
    this.color = Colors.white,
  });

  final String contentId;
  final String authorId;
  final String? authorName;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(isBlockedProvider(authorId)).value ?? false;

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: color),
      tooltip: 'Plus',
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'report',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.flag_outlined),
            title: Text('Signaler'),
          ),
        ),
        PopupMenuItem(
          value: blocked ? 'unblock' : 'block',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(blocked ? Icons.person_add_alt : Icons.block),
            title: Text(blocked ? 'Débloquer' : 'Bloquer'),
          ),
        ),
      ],
      onSelected: (v) async {
        final repo = ref.read(moderationRepositoryProvider);
        switch (v) {
          case 'report':
            await showReportSheet(
              context,
              ref,
              contentId: contentId,
              targetUserId: authorId,
              targetName: authorName,
            );
          case 'block':
            final ok = await _confirmBlock(context);
            if (ok != true) return;
            await repo.block(authorId);
            ref.invalidate(blockedProfilesProvider);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '${authorName ?? 'Cette personne'} est bloquée.',
                  ),
                ),
              );
              Navigator.of(context).maybePop();
            }
          case 'unblock':
            await repo.unblock(authorId);
            ref.invalidate(blockedProfilesProvider);
        }
      },
    );
  }

  Future<bool?> _confirmBlock(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Bloquer ${authorName ?? 'cette personne'} ?'),
      content: const Text(
        'Vous ne verrez plus vos contenus respectifs, et aucun partage ne '
        'pourra vous relier — même par un ami commun.\n\n'
        'La personne n\'en sera pas informée. Tu peux annuler à tout moment '
        'depuis Réglages.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Bloquer'),
        ),
      ],
    ),
  );
}
