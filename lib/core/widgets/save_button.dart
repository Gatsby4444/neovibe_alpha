import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../content/saved_store.dart';
import '../models/card.dart';

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
  });

  final String contentId;
  final CardType cardType;
  final bool canSave;

  /// Les faces **en clair**, telles qu'affichées. Nulles tant que le
  /// déchiffrement n'a pas abouti : le bouton est alors inerte.
  final File? front;
  final File? back;

  final bool frontIsVideo;
  final bool backIsVideo;
  final String? authorName;
  final bool mine;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canSave) return const SizedBox.shrink();
    final saved = ref.watch(isSavedProvider(contentId)).value ?? false;
    final ready = front != null;

    return IconButton(
      color: color,
      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
      tooltip: saved
          ? 'Retirer de mes Enregistrements'
          : 'Enregistrer sur cet appareil',
      onPressed: !ready && !saved ? null : () => _toggle(context, ref, saved),
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
          front: front!,
          back: back,
          frontIsVideo: frontIsVideo,
          backIsVideo: backIsVideo,
          authorName: authorName,
          mine: mine,
        );
      }
      ref.invalidate(isSavedProvider(contentId));
      ref.invalidate(savedItemsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved
                  ? 'Retiré de tes Enregistrements.'
                  : 'Enregistré sur cet appareil.',
            ),
          ),
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
