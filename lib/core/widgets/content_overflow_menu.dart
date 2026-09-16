import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'action_button.dart';

import '../content/moderation.dart';
import 'report_sheet.dart';

/// Le menu « … » de modération : signaler, bloquer.
///
/// Il sert **deux cibles avec le même geste** :
/// - posé sur un contenu d'autrui ([contentId] renseigné), il signale le
///   contenu ;
/// - posé sur le profil de quelqu'un ([contentId] nul), il signale la
///   personne.
///
/// Un seul menu pour les deux, parce que c'est la même décision côté
/// utilisateur — seule la cible enregistrée change. Le blocage, lui, vise
/// toujours la personne.
///
/// On ne se signale **jamais soi-même** : sur mon propre contenu ([mine]),
/// le menu ne propose pas le signalement mais **les options du propriétaire**
/// — « Retirer » aujourd'hui, d'autres demain. C'est la demande de Jay du
/// 2026-09-16 : la corbeille quitte la barre d'actions pour ce menu, *« puisqu'on
/// va en ajouter et que les options de ce type seront dedans »*. Un seul « … »
/// partout, dont le contenu dépend de qui regarde — pas deux boutons
/// différents selon le cas.
///
/// C'est le seul point d'entrée de la modération côté utilisateur, et il est
/// volontairement au même endroit partout : quelqu'un qui tombe sur un contenu
/// choquant ne doit pas avoir à chercher.
///
/// ⚠️ **Le profil est le point d'entrée de dernier recours** : une Vibe reçue
/// en DM n'a pas de Content ID (elle ne rejoindra le socle que le jour où
/// `cards` y migrera), elle se signale donc par le profil de son expéditeur.
/// Ce chemin est resté inatteignable de la v0.9.53 au 2026-08-12 — le menu
/// n'existait que sur les stories et les publications.
class ContentOverflowMenu extends ConsumerWidget {
  const ContentOverflowMenu({
    super.key,
    this.contentId,
    required this.authorId,
    this.authorName,
    this.color = Colors.white,
    this.mine = false,
    this.onRemove,
    this.dense = false,
  });

  /// Nul quand le menu porte sur une personne et non sur un contenu.
  final String? contentId;
  final String authorId;
  final String? authorName;
  final Color color;

  /// Ce contenu est le mien : les options du propriétaire, pas celles de la
  /// modération.
  final bool mine;

  /// « Retirer », quand c'est le mien. Nul = l'option n'existe pas ici.
  final VoidCallback? onRemove;

  /// Resserré, pour l'en-tête d'une cellule du fil (voir [ActionMetrics]).
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mon contenu sans aucune option de propriétaire : pas de menu vide.
    if (mine && onRemove == null) return const SizedBox.shrink();
    final blocked = mine
        ? false
        : ref.watch(isBlockedProvider(authorId)).value ?? false;

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: color),
      tooltip: 'Plus',
      iconSize: ActionMetrics.icon(dense),
      padding: ActionMetrics.padding(dense),
      itemBuilder: (context) => mine
          ? [
              const PopupMenuItem(
                value: 'remove',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline),
                  title: Text('Retirer'),
                ),
              ),
            ]
          : [
              PopupMenuItem(
                value: 'report',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.flag_outlined),
                  title: Text(
                    contentId != null ? 'Signaler ce contenu' : 'Signaler',
                  ),
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
          case 'remove':
            onRemove?.call();
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
