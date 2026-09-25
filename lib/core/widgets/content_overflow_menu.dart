import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import '../typography.dart';
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
/// ⚠️ **Le profil reste le point d'entrée de dernier recours.** Une Vibe
/// reçue en DM n'a pas de Content ID ; jusqu'au 2026-09-25 elle ne se
/// signalait QUE par le profil de son expéditeur. Elle a désormais son propre
/// signalement ([SentVibeReportTarget]).
///
/// ### Les Vibes, depuis le 2026-09-25
///
/// Même menu pour une Vibe du Drop et une Vibe reçue en chat (Jay) : à son
/// auteur **Modifier** ([onEdit]) et **Supprimer** ([onRemove]) ; aux autres
/// **Supprimer pour moi** ([onHide]), **Signaler** ([reportTarget]) et
/// **Bloquer** — et, à l'organisateur d'une soirée, **Supprimer du Drop**
/// ([onModeratorRemove]). Le menu ne décide d'aucun droit : le serveur
/// refuse ce qui ne l'est pas ; il n'affiche que ce qui a un sens.
class ContentOverflowMenu extends ConsumerWidget {
  const ContentOverflowMenu({
    super.key,
    this.contentId,
    this.reportTarget,
    required this.authorId,
    this.authorName,
    this.color = Colors.white,
    this.mine = false,
    this.onRemove,
    this.removeLabel = 'Retirer',
    this.removeDetail = 'Cette publication disparaît pour tout le monde.',
    this.onEdit,
    this.onHide,
    this.onModeratorRemove,
    this.dense = false,
  });

  /// Nul quand le menu porte sur une personne et non sur un contenu.
  final String? contentId;

  /// Ce que « Signaler » vise, quand ce n'est ni un contenu du socle ni la
  /// personne (une Vibe du Drop, une Vibe reçue).
  final ReportTarget? reportTarget;
  final String authorId;
  final String? authorName;
  final Color color;

  /// Ce contenu est le mien : les options du propriétaire, pas celles de la
  /// modération.
  final bool mine;

  /// « Retirer », quand c'est le mien. Nul = l'option n'existe pas ici.
  final VoidCallback? onRemove;
  final String removeLabel;
  final String removeDetail;

  /// « Modifier », quand c'est le mien.
  final VoidCallback? onEdit;

  /// « Supprimer pour moi », quand ce n'est pas le mien.
  final VoidCallback? onHide;

  /// « Supprimer du Drop », pour l'organisateur quand ce n'est pas le sien.
  final VoidCallback? onModeratorRemove;

  /// Resserré, pour l'en-tête d'une cellule du fil (voir [ActionMetrics]).
  final bool dense;

  bool get _vide => mine && onRemove == null && onEdit == null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mon contenu sans aucune option de propriétaire : pas de menu vide.
    if (_vide) return const SizedBox.shrink();
    // ⚠️ Lu ICI, pas seulement dans la feuille : un `read` sur un provider
    // que personne n'a demandé rend `null` — la feuille aurait proposé
    // « Bloquer » à quelqu'un de déjà bloqué, une fois sur deux.
    if (!mine) ref.watch(isBlockedProvider(authorId));

    return ActionIconButton(
      icon: const Icon(Icons.more_vert),
      color: color,
      dense: dense,
      tooltip: 'Plus',
      onPressed: () => open(context, ref),
    );
  }

  /// **La feuille, pas le menu déroulant** (Jay, 2026-09-17 : *« le rendu est
  /// peu professionnel et premium, fais comme sur Insta : un menu se déroule
  /// depuis le bas de l'écran »*).
  ///
  /// Ce n'est pas qu'une question de goût : un menu déroulant se pose à côté
  /// du bouton, donc sa taille dépend de la place qui reste et ses options
  /// arrivent là où l'œil n'est pas. Une feuille arrive toujours du même
  /// bord, à portée du pouce, et peut grandir — ce qui compte quand on sait
  /// que les options vont se multiplier.
  ///
  /// Publique (2026-09-25) : un appui long sur une tuile du Drop ou sur un
  /// container de Vibe ouvre la même feuille que le « … ».
  Future<void> open(BuildContext context, WidgetRef ref) async {
    if (_vide) return;
    final blocked = mine
        ? false
        : await ref
              .read(isBlockedProvider(authorId).future)
              .catchError((_) => false);
    if (!context.mounted) return;
    final vise = reportTarget;
    final labelSignaler = switch (vise) {
      DropVibeReportTarget() || SentVibeReportTarget() => 'Signaler',
      _ => contentId != null ? 'Signaler ce contenu' : 'Signaler',
    };

    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mine) ...[
              if (onEdit != null)
                _Option(
                  icon: Icons.tune,
                  label: 'Modifier',
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
              if (onRemove != null)
                _Option(
                  icon: Icons.delete_outline,
                  label: removeLabel,
                  detail: removeDetail,
                  danger: true,
                  onTap: () => Navigator.pop(context, 'remove'),
                ),
            ] else ...[
              if (onHide != null)
                _Option(
                  icon: Icons.visibility_off_outlined,
                  label: 'Supprimer pour moi',
                  detail: 'Elle disparaît pour toi seulement.',
                  onTap: () => Navigator.pop(context, 'hide'),
                ),
              _Option(
                icon: Icons.flag_outlined,
                label: labelSignaler,
                onTap: () => Navigator.pop(context, 'report'),
              ),
              _Option(
                icon: blocked ? Icons.person_add_alt : Icons.block,
                label: blocked ? 'Débloquer' : 'Bloquer',
                detail: blocked
                    ? null
                    : 'Vous ne verrez plus vos contenus respectifs.',
                danger: !blocked,
                onTap: () =>
                    Navigator.pop(context, blocked ? 'unblock' : 'block'),
              ),
              if (onModeratorRemove != null)
                _Option(
                  icon: Icons.delete_outline,
                  label: 'Supprimer du Drop',
                  detail:
                      'Tu organises cette soirée : elle disparaît pour '
                      'tout le monde.',
                  danger: true,
                  onTap: () => Navigator.pop(context, 'moderate'),
                ),
            ],
            const SizedBox(height: NeoSpace.sm),
          ],
        ),
      ),
    );
    if (choix == null || !context.mounted) return;
    await _appliquer(context, ref, choix);
  }

  Future<void> _appliquer(BuildContext context, WidgetRef ref, String v) async {
    final repo = ref.read(moderationRepositoryProvider);
    switch (v) {
      case 'edit':
        onEdit?.call();
      case 'remove':
        onRemove?.call();
      case 'hide':
        onHide?.call();
      case 'moderate':
        onModeratorRemove?.call();
      case 'report':
        await showReportSheet(
          context,
          ref,
          contentId: contentId,
          target: reportTarget,
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
              content: Text('${authorName ?? 'Cette personne'} est bloquée.'),
            ),
          );
          Navigator.of(context).maybePop();
        }
      case 'unblock':
        await repo.unblock(authorId);
        ref.invalidate(blockedProfilesProvider);
    }
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

/// Une option de la feuille : une icône, un libellé, et ce que ça fait
/// vraiment en dessous quand ce n'est pas évident.
class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.label,
    required this.onTap,
    this.detail,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final couleur = danger
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: couleur),
      title: Text(
        label,
        style: TextStyle(color: couleur, fontWeight: FontWeight.w600),
      ),
      subtitle: detail == null
          ? null
          : Text(detail!, style: TextStyle(color: context.muted, fontSize: 12)),
      onTap: onTap,
    );
  }
}
