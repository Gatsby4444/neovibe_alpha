import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../content/saved_store.dart';
import '../crypto/media_open.dart';
import '../models/card.dart';
import 'action_button.dart';

/// Le bouton « Enregistrer », commun aux trois visionneuses.
///
/// Il ne parle **jamais** au serveur : les fichiers qu'on lui passe sont déjà
/// déchiffrés à l'écran, il ne fait que les copier dans les Enregistrements.
/// C'est ce qui rend la sauvegarde instantanée et disponible hors ligne.
///
/// [canSave] porte la décision de l'auteur — `cards.saveable` pour une Vibe
/// envoyée, `contents.saveable` pour une story ou une publication. Le bouton
/// n'apparaît pas si l'auteur ne l'a pas accordé : mieux vaut une absence
/// qu'un bouton qui échoue.
class SaveButton extends ConsumerWidget {
  const SaveButton({
    super.key,
    required this.contentId,
    required this.cardType,
    required this.canSave,
    required this.front,
    this.back,
    this.frontIsVideo = false,
    this.backIsVideo = false,
    this.authorName,
    this.mine = false,
    this.color = Colors.white,
    this.dense = false,
  });

  final String contentId;
  final CardType cardType;
  final bool canSave;

  /// Les faces **ouvertes**, telles qu'affichées. Nulles tant que
  /// l'ouverture n'a pas abouti : le bouton est alors inerte.
  ///
  /// Une sauvegarde régénère le clair depuis le scellé — l'affichage, lui, ne
  /// l'écrit plus sur le disque depuis le format par blocs.
  final OpenedMedia? front;
  final OpenedMedia? back;

  final bool frontIsVideo;
  final bool backIsVideo;
  final String? authorName;
  final bool mine;
  final Color color;

  /// Resserré, pour l'en-tête d'une cellule du fil (voir [ActionMetrics]).
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canSave) return const SizedBox.shrink();
    final saved = ref.watch(isSavedProvider(contentId)).value ?? false;
    // En cours d'écriture : le bouton est déjà plein, et inerte le temps que
    // ça finisse — un second appui n'aurait rien à ajouter ni à retirer.
    final saving = ref.watch(
      savingIdsProvider.select((ids) => ids.contains(contentId)),
    );
    final ready = front != null;

    return ActionIconButton(
      color: color,
      dense: dense,
      icon: Icon(saved || saving ? Icons.bookmark : Icons.bookmark_border),
      tooltip: saved
          ? 'Retirer de mes Enregistrements'
          : 'Enregistrer sur cet appareil',
      onPressed: saving || (!ready && !saved)
          ? null
          : () => _toggle(context, ref, saved),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool saved) async {
    final store = ref.read(savedStoreProvider);
    try {
      if (saved) {
        await store.remove(contentId);
      } else {
        await store.add(
          contentId: contentId,
          cardType: cardType,
          writeFront: front!.writeClearTo,
          writeBack: back?.writeClearTo,
          frontIsVideo: frontIsVideo,
          backIsVideo: backIsVideo,
          authorName: authorName,
          mine: mine,
        );
      }
      // Plus de message « Enregistré » : le bouton l'a dit à l'appui. Retirer
      // reste annoncé — c'est une perte, elle mérite une phrase.
      if (saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Retiré de tes Enregistrements.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }
}
