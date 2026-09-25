import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formats.dart';
import '../../core/content/saved_store.dart';
import '../../core/models/card.dart';
import '../../core/theme.dart';
import '../../core/widgets/card_type_badge.dart';
import '../../core/crypto/media_open.dart';
import '../../core/widgets/vibe_face.dart';
import '../../core/widgets/pull_down_to_close.dart';
import 'flippable_card.dart';
import '../../core/widgets/system_bars.dart';

// ⚠️ **L'écran « Enregistrements » a été RETIRÉ le 2026-09-25** : la galerie
// (`features/gallery/gallery_screen.dart`) montre désormais ces mêmes Vibes,
// datées et situées (Jay). Deux écrans pour une même donnée, c'étaient deux
// chemins qui auraient divergé. Restent ici la vignette et le lecteur d'un
// Enregistrement, que la galerie et l'historique des soirées utilisent.

/// Vignette d'un Enregistrement : le fichier est en clair sur l'appareil,
/// donc rien à déchiffrer ni à télécharger.
class SavedTile extends ConsumerWidget {
  const SavedTile({super.key, required this.item});
  final SavedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => SavedViewerScreen(item: item))),
      onLongPress: () => _confirmRemove(context, ref),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: item.cardType.color, width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          // Vignettes d'habillage : fond et icône suivent le thème. En dur,
          // c'était un gris violacé et une icône `white38`, invisible en
          // thème clair.
          child: item.frontIsVideo
              ? ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Icon(Icons.videocam, color: context.faint, size: 26),
                  ),
                )
              : Image.file(
                  File(item.frontPath),
                  fit: BoxFit.cover,
                  cacheWidth: 400,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.broken_image,
                        color: context.faint,
                        size: 26,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer de mes Enregistrements ?'),
        content: const Text(
          'La copie sur cet appareil sera supprimée. Si le contenu existe '
          'encore chez son auteur, tu pourras le réenregistrer.',
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
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(savedStoreProvider).remove(item.contentId);
    } catch (e) {
      // ⚠️ Sans ça, l'écran rafraîchissait la liste comme si la suppression
      // avait eu lieu. L'entrée réapparaissait au rechargement suivant, sans
      // que rien n'ait jamais dit non.
      messenger.showSnackBar(
        const SnackBar(content: Text('Impossible de retirer cet élément.')),
      );
      return;
    }
    // L'invalidation est faite par le magasin, à l'écriture (2026-09-18).
  }
}

/// Lecture d'un Enregistrement. Aucun réseau, aucune clé : le fichier est là.
/// Public depuis le 2026-09-21 : la galerie (`gallery_screen.dart`) ouvre
/// les Vibes gardées d'un moment par ce même lecteur.
class SavedViewerScreen extends StatefulWidget {
  const SavedViewerScreen({super.key, required this.item});
  final SavedItem item;

  @override
  State<SavedViewerScreen> createState() => SavedViewerScreenState();
}

class SavedViewerScreenState extends State<SavedViewerScreen> {
  var _showFront = true;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // Un Enregistrement est en clair par conception : rien à déchiffrer, rien
    // à demander au serveur — il s'ouvre hors ligne.
    Widget face(String path, bool isVideo, bool active) => isVideo
        ? VibeVideoFace(
            media: OpenedMedia.clear(File(path)),
            type: item.cardType,
            active: active,
          )
        : _SavedPhoto(path: path, type: item.cardType);

    final front = face(item.frontPath, item.frontIsVideo, _showFront);

    // Tirer vers le bas ferme — le geste unique des visionneurs plein écran
    // (Jay, 2026-09-14). Même conséquence que la croix.
    return PullDownToClose(
      onClose: () => Navigator.of(context).maybePop(),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          systemOverlayStyle: kSystemBarsOnDark,
          title: CardTypeBadge(type: item.cardType, fontSize: 12),
        ),
        body: Center(
          child: item.hasBack
              ? FlippableCard(
                  onSideChanged: (f) => setState(() => _showFront = f),
                  front: front,
                  back: face(item.backPath!, item.backIsVideo, !_showFront),
                )
              : TiltableCard(child: front),
        ),
        // Quand, où, et de quelle soirée (2026-09-25) — ce que la galerie
        // range. Une sauvegarde d'avant n'a que sa date d'enregistrement.
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 14),
            child: Text(
              [
                dayAndTime(item.when),
                ?item.where,
                ?item.eventTitle,
              ].join(' · '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }
}

/// Une photo enregistrée : lue depuis le disque, où elle est en clair.
///
/// ⚠️ **La lecture n'est plus créée dans `build()`** (2026-08-25, checkup #52).
/// Elle l'était, et repartait donc à zéro à chaque reconstruction : une lecture
/// disque de plus, et un retour au rond de chargement, sans que rien ne
/// s'affiche de faux.
class _SavedPhoto extends ConsumerWidget {
  const _SavedPhoto({required this.path, required this.type});

  final String path;
  final CardType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(savedPhotoBytesProvider(path)).value;
    if (bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return VibePhotoFace(bytes: bytes, type: type);
  }
}
