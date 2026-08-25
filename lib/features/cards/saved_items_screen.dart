import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/saved_store.dart';
import '../../core/models/card.dart';
import '../../core/theme.dart';
import '../../core/widgets/card_type_badge.dart';
import '../../core/crypto/media_open.dart';
import '../../core/widgets/vibe_face.dart';
import '../library/mini_card.dart' show kMiniCardRatio;
import 'flippable_card.dart';

enum _SavedFilter { mine, others }

/// Enregistrements : la bibliothèque PRIVÉE, visible de moi seul.
///
/// ⚠️ Entièrement **locale** depuis le 2026-08-11. Cet écran ne fait plus
/// aucun appel serveur : les fichiers sont sur l'appareil, en clair, et
/// s'affichent hors ligne. C'est le volet 3 de Jay — « plus besoin d'appeler
/// le serveur pour les afficher, pas d'espace serveur dédié ».
///
/// Ce que ça corrige : `saved_cards` était en `ON DELETE CASCADE`. Si l'auteur
/// supprimait sa Vibe, tous ceux qui l'avaient enregistrée la perdaient — alors
/// qu'« Enregistrer » promet de garder. Désormais une sauvegarde ne dépend que
/// de son propriétaire ; seule la **modération** peut la retirer.
class SavedItemsScreen extends ConsumerStatefulWidget {
  const SavedItemsScreen({super.key});

  @override
  ConsumerState<SavedItemsScreen> createState() => _SavedItemsScreenState();
}

class _SavedItemsScreenState extends ConsumerState<SavedItemsScreen> {
  var _filter = _SavedFilter.mine;

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(savedItemsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Enregistrements')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<_SavedFilter>(
              segments: const [
                ButtonSegment(
                  value: _SavedFilter.mine,
                  label: Text('Moi'),
                  icon: Icon(Icons.person, size: 16),
                ),
                ButtonSegment(
                  value: _SavedFilter.others,
                  label: Text('Les autres'),
                  icon: Icon(Icons.people, size: 16),
                ),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
          Expanded(
            child: saved.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Erreur : $e'),
                ),
              ),
              data: (all) {
                final list = all
                    .where((i) => i.mine == (_filter == _SavedFilter.mine))
                    .toList();
                if (list.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _filter == _SavedFilter.mine
                            ? 'Rien d\'enregistré.\nCoche « Enregistrer pour '
                                  'moi » à l\'envoi pour garder une Vibe ici, '
                                  'définitivement.'
                            : 'Rien d\'enregistré.\nOuvre une Vibe, une story '
                                  'ou une publication que son auteur a rendue '
                                  'sauvegardable, puis touche le signet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.muted),
                      ),
                    ),
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 80),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: kMiniCardRatio,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, i) => _SavedTile(item: list[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Vignette d'un Enregistrement : le fichier est en clair sur l'appareil,
/// donc rien à déchiffrer ni à télécharger.
class _SavedTile extends ConsumerWidget {
  const _SavedTile({required this.item});
  final SavedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => _SavedViewerScreen(item: item))),
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
    ref.invalidate(savedItemsProvider);
    ref.invalidate(isSavedProvider(item.contentId));
  }
}

/// Lecture d'un Enregistrement. Aucun réseau, aucune clé : le fichier est là.
class _SavedViewerScreen extends StatefulWidget {
  const _SavedViewerScreen({required this.item});
  final SavedItem item;

  @override
  State<_SavedViewerScreen> createState() => _SavedViewerScreenState();
}

class _SavedViewerScreenState extends State<_SavedViewerScreen> {
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

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
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
