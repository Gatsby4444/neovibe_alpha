import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// Il n'apparaît **jamais sur son propre contenu ni sur son propre profil** —
/// on ne se signale pas soi-même, et proposer l'action y serait au mieux du
/// bruit.
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
  });

  /// Nul quand le menu porte sur une personne et non sur un contenu.
  final String? contentId;
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
        PopupMenuItem(
          value: 'report',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.flag_outlined),
            title: Text(contentId != null ? 'Signaler ce contenu' : 'Signaler'),
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
