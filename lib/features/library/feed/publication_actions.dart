import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_repost.dart';
import '../../../core/content/likes.dart';
import '../../../core/crypto/media_open.dart';
import '../../../core/models/library_item.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/utils/formats.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/action_button.dart';
import '../../../core/widgets/content_overflow_menu.dart';
import '../../../core/widgets/save_button.dart';
import '../../cards/send/recipient_picker_screen.dart';
import '../../cards/send/share_context.dart';
import '../../cards/send/share_plan.dart';
import '../library_repository.dart';
import '../open_profile.dart';
import 'edit_caption_sheet.dart';
import '../../connections/connections_repository.dart';

/// **Les actions d'une publication** — aimer, enregistrer, partager, et le
/// menu « … ».
///
/// Deux poses, le même contenu :
/// - **à plat et resserré**, dans l'en-tête d'une cellule du fil, sur la ligne
///   de l'avatar et du pseudo (Jay, 2026-09-16 : sous la carte, la cellule ne
///   tenait plus dans un écran) ;
/// - **en colonne**, sur la carte en plein écran, à droite — donc *dans* la
///   carte : elles s'inclinent et se retournent avec elle, et les deux faces
///   portent les mêmes, dans les mêmes états (ces états viennent des
///   providers, pas du widget : ils ne peuvent pas diverger).
///
/// ⚠️ **Plus de corbeille dans la barre** : « Retirer » vit dans le menu,
/// avec les options du même genre à venir (Jay, 2026-09-16).
class PublicationActions extends ConsumerWidget {
  const PublicationActions({
    super.key,
    required this.item,
    required this.mine,
    required this.saveId,
    required this.saveFront,
    this.saveBack,
    this.saveFrontIsVideo = false,
    this.saveBackIsVideo = false,
    this.vertical = false,
    this.dense = false,
    this.color,
    this.onDeleted,
    this.onChanged,
  });

  final LibraryItem item;
  final bool mine;

  /// Ce que « Enregistrer » copie : pour une Card ses deux faces, pour un
  /// album le média affiché (clé locale composée `id#place`).
  final String saveId;
  final OpenedMedia? saveFront;
  final OpenedMedia? saveBack;
  final bool saveFrontIsVideo;
  final bool saveBackIsVideo;

  /// En colonne (plein écran) plutôt qu'à plat.
  final bool vertical;

  /// Resserré : l'en-tête d'une cellule du fil (voir [ActionMetrics]).
  final bool dense;

  /// La couleur des icônes ; par défaut l'encre du thème.
  final Color? color;

  /// Après « Retirer » : l'écran qui nous contient décide (fermer, ou
  /// retirer la cellule).
  final VoidCallback? onDeleted;

  /// Après « Modifier la description » : la publication mise à jour, pour
  /// l'écran qui tient une copie de la liste. Le dépôt a déjà invalidé la
  /// grille ; ici, c'est l'exemplaire à l'écran qu'on remplace.
  final ValueChanged<LibraryItem>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ink = color ?? Theme.of(context).colorScheme.onSurface;
    final children = [
      LikeButton(
        contentId: item.id,
        color: ink,
        vertical: vertical,
        dense: dense,
      ),
      SaveButton(
        contentId: saveId,
        cardType: item.cardType,
        canSave: item.saveable || mine,
        front: saveFront,
        back: saveBack,
        frontIsVideo: saveFrontIsVideo,
        backIsVideo: saveBackIsVideo,
        mine: mine,
        color: ink,
        dense: dense,
      ),
      if (item.shareable)
        ActionIconButton(
          icon: const Icon(Icons.reply_outlined),
          color: ink,
          dense: dense,
          tooltip: 'Partager dans une conversation',
          onPressed: () => _share(context, ref),
        ),
      ContentOverflowMenu(
        contentId: item.id,
        authorId: item.ownerId,
        color: ink,
        dense: dense,
        mine: mine,
        onRemove: mine ? () => _confirmDelete(context, ref) : null,
        // Une Vibe n'a pas de description (Jay, 2026-09-17) : rien à modifier.
        onEditCaption: mine && item.isPublication
            ? () => _editCaption(context, ref)
            : null,
      ),
    ];
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: children)
        : Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Future<void> _editCaption(BuildContext context, WidgetRef ref) async {
    final updated = await showEditCaptionSheet(context, item);
    if (updated != null) onChanged?.call(updated);
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    // Le même écran « À qui ? » que la capture, en mode repartage.
    final plan = await Navigator.of(context).push<SharePlan>(
      MaterialPageRoute(
        builder: (_) => RecipientPickerScreen(
          shareContext: RepostShareContext(
            contentId: item.id,
            what: 'publication',
          ),
        ),
      ),
    );
    if (plan == null || !context.mounted) return;
    try {
      final resultat = await ref
          .read(contentRepostProvider)
          .toPlan(item.id, plan);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(resultat)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer cette publication ?'),
        content: const Text(
          'Elle disparaît pour tout le monde, y compris pour ceux à qui elle a '
          'été repartagée — un repartage est un raccourci vers celle-ci, pas '
          'une copie.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (delete != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(libraryRepositoryProvider).removeItem(item.id);
    } catch (_) {
      // Fermer, c'est dire que c'est fait : on ne ferme pas sur un échec.
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Impossible de retirer cette publication.'),
        ),
      );
      return;
    }
    onDeleted?.call();
  }
}

/// Le cœur et son compte. Le compte ouvre « qui a aimé ».
class LikeButton extends ConsumerWidget {
  const LikeButton({
    super.key,
    required this.contentId,
    required this.color,
    this.vertical = false,
    this.dense = false,
  });

  final String contentId;
  final Color color;
  final bool vertical;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(likesStoreProvider.select((m) => m[contentId]));
    final liked = state?.liked ?? false;
    final count = state?.count ?? 0;
    final heart = ActionIconButton(
      icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
      color: liked ? const Color(0xFFFF2D55) : color,
      dense: dense,
      tooltip: liked ? 'Ne plus aimer' : 'Aimer',
      onPressed: () async {
        try {
          await ref.read(likesStoreProvider.notifier).toggle(contentId);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Impossible pour l\'instant.')),
            );
          }
        }
      },
    );
    // Personne n'a encore aimé : pas de compte du tout. Un libellé vide
    // occupe quand même une ligne, et décalait la colonne du plein écran.
    if (count == 0) {
      return vertical
          ? heart
          : Padding(
              padding: const EdgeInsets.only(right: NeoSpace.sm),
              child: heart,
            );
    }
    final label = GestureDetector(
      onTap: () => showLikers(context, ref, contentId),
      child: Padding(
        padding: EdgeInsets.only(right: vertical ? 0 : NeoSpace.sm),
        child: Text(
          '$count',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: [heart, label])
        : Row(mainAxisSize: MainAxisSize.min, children: [heart, label]);
  }
}

/// « Qui a aimé » — une feuille avec les personnes, les plus récentes en
/// premier.
Future<void> showLikers(
  BuildContext context,
  WidgetRef ref,
  String contentId,
) async {
  final store = ref.read(likesStoreProvider.notifier);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: FutureBuilder<List<Liker>>(
          future: store.likers(contentId),
          builder: (context, snap) {
            final likers = snap.data;
            if (likers == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (likers.isEmpty) {
              return Center(
                child: Text(
                  'Personne pour l\'instant.',
                  style: TextStyle(color: context.muted),
                ),
              );
            }
            return ListView.builder(
              itemCount: likers.length,
              itemBuilder: (context, i) {
                final l = likers[i];
                return ListTile(
                  leading: Avatar(
                    stored: l.avatarUrl,
                    radius: 18,
                    fallback: Text(
                      l.displayName.isEmpty
                          ? '?'
                          : l.displayName[0].toUpperCase(),
                    ),
                  ),
                  title: Text(l.displayName),
                  subtitle: Text(
                    timeAgo(l.likedAt),
                    style: TextStyle(color: context.muted, fontSize: 12),
                  ),
                  // Une personne nommée mène à son profil — ici comme
                  // ailleurs (Jay, 2026-09-17). La feuille se referme
                  // d'abord : on ne laisse pas un écran par-dessus l'autre.
                  onTap: () async {
                    final profil = await ref.read(
                      profileByIdProvider(l.id).future,
                    );
                    if (!context.mounted || profil == null) return;
                    Navigator.of(context).pop();
                    openProfile(context, profil);
                  },
                );
              },
            );
          },
        ),
      ),
    ),
  );
}
