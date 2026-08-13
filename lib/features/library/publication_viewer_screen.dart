import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/content/content_view_reporter.dart';
import '../../core/crypto/media_open.dart';
import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/video/video_open_trace.dart';
import '../../core/widgets/card_type_badge.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../../core/widgets/save_button.dart';
import '../../core/widgets/vibe_face.dart';
import '../cards/flippable_card.dart';
import '../conversations/conversations_repository.dart';
import 'library_repository.dart';

/// Lecture plein écran d'une **publication** de bibliothèque.
///
/// Écran distinct de `CardViewerScreen` pour la même raison que la visionneuse
/// de stories : celui-ci est bâti sur les livraisons, les budgets de vues et
/// les durées de lecture. Une publication n'a rien de tout cela — elle se
/// regarde sans limite. Y faire transiter son média imposerait de neutraliser
/// chaque mécanisme au cas par cas, c'est-à-dire de refaire le mélange que la
/// refonte supprime.
class PublicationViewerScreen extends ConsumerStatefulWidget {
  const PublicationViewerScreen({super.key, required this.item});
  final LibraryItem item;

  @override
  ConsumerState<PublicationViewerScreen> createState() =>
      _PublicationViewerScreenState();
}

class _PublicationViewerScreenState
    extends ConsumerState<PublicationViewerScreen> {
  var _showFront = true;

  /// ⚠️ Capturé à l'initialisation. **`ref` est interdit dans `dispose()`** :
  /// le widget y est déjà démonté. La v0.9.64 l'appelait ici, et le journal de
  /// Jay a relevé 19 « Using "ref" when a widget is about to or has been
  /// unmounted » en une session.
  late final ContentViewReporter _reporter;

  @override
  void initState() {
    super.initState();
    _reporter = ref.read(contentViewReporterProvider);
    // La vue ne part qu'après 3 s d'affichage réel (consigne de Jay du
    // 2026-08-13) : ouvrir puis refermer aussitôt n'est pas un visionnage.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reporter.watching(widget.item.id);
    });
  }

  @override
  void dispose() {
    _reporter.stopped(widget.item.id);
    super.dispose();
  }

  ContentFace _spec(bool front) => (
    contentId: widget.item.id,
    ownerId: widget.item.ownerId,
    bucket: 'library',
    path: front ? widget.item.frontPath : widget.item.backPath!,
    front: front,
    isVideo: front ? widget.item.frontIsVideo : widget.item.backIsVideo,
    encrypted: widget.item.encrypted,
    // Un contenu isolé : un appel de clé suffit, pas de lot à charger.
    batchOwner: null,
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final mine = item.ownerId == ref.watch(currentUserIdProvider);
    final front = ref.watch(contentFaceProvider(_spec(true)));
    // Le verso est demandé DÈS L'OUVERTURE, alors qu'il ne s'affiche qu'au
    // retournement : c'est un préchargement, et il faut le dire à la mesure.
    // Sans ça, le chronomètre du verso tourne pendant que l'utilisateur
    // regarde le recto — au relevé du 2026-08-13, une face arrière affichait
    // 11 s d'« attente » qui n'étaient que du temps de lecture.
    final back = item.hasBack
        ? ref.watch(contentFaceProvider(_spec(false)))
        : null;
    if (item.hasBack && item.backIsVideo) {
      VideoOpenTrace.markPrefetched(item.id, front: false);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: CardTypeBadge(type: item.cardType, fontSize: 12),
        actions: [
          // Enregistrer : une copie EN CLAIR sur l'appareil, à partir des
          // fichiers déjà déchiffrés à l'écran. Aucun appel serveur.
          SaveButton(
            contentId: item.id,
            cardType: item.cardType,
            canSave: item.saveable || mine,
            front: front.value,
            back: back?.value,
            frontIsVideo: item.frontIsVideo,
            backIsVideo: item.backIsVideo,
            mine: mine,
          ),
          // Le bouton n'existe que si l'auteur a autorisé le relais : sans
          // quoi il proposerait une action que le serveur refuserait.
          if (item.shareable)
            IconButton(
              icon: const Icon(Icons.reply_outlined),
              tooltip: 'Partager dans une conversation',
              onPressed: _share,
            ),
          if (mine)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Retirer de ma bibliothèque',
              onPressed: _confirmDelete,
            ),
          // Signaler / bloquer : jamais sur son propre contenu.
          if (!mine)
            ContentOverflowMenu(contentId: item.id, authorId: item.ownerId),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: front.when(
              loading: () => const Center(
                child: CircularProgressIndicator(color: Colors.white24),
              ),
              error: (e, _) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Cette publication n\'est plus disponible.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
              data: (frontFile) {
                final frontFace = _face(
                  frontFile,
                  item.frontIsVideo,
                  _showFront,
                );
                // ⚠️ La structure ne dépend QUE de `hasBack`, constant pendant
                // toute la vie de l'écran — jamais de l'arrivée du verso.
                // Choisir d'après `backFile == null` faisait changer le TYPE du
                // widget à cette position, ce qui détruisait et reconstruisait
                // le lecteur du recto (voir [VibeFaceLoading]).
                if (!item.hasBack) {
                  return Center(child: TiltableCard(child: frontFace));
                }
                final backFile = back?.value;
                return Center(
                  child: FlippableCard(
                    onSideChanged: (f) => setState(() => _showFront = f),
                    front: frontFace,
                    back: backFile == null
                        ? VibeFaceLoading(type: item.cardType)
                        : _face(backFile, item.backIsVideo, !_showFront),
                  ),
                );
              },
            ),
          ),
          if (item.caption != null && item.caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Text(
                item.caption!,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }

  /// Une publication reste une Vibe : même cadre, même couleur de type.
  /// Seules les RÈGLES diffèrent, pas l'apparence.
  Widget _face(OpenedMedia m, bool isVideo, bool active) => isVideo
      ? VibeVideoFace(media: m, type: widget.item.cardType, active: active)
      : VibePhotoFace(bytes: m.photoBytes!, type: widget.item.cardType);

  Future<void> _share() async {
    final conversationId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF16161C),
      builder: (_) => const _ConversationPicker(),
    );
    if (conversationId == null || !mounted) return;
    try {
      final added = await ref
          .read(libraryRepositoryProvider)
          .shareToConversation(widget.item.id, conversationId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added == 0
                ? 'Déjà partagée dans cette conversation.'
                : 'Publication partagée à $added personne'
                      '${added > 1 ? 's' : ''}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  Future<void> _confirmDelete() async {
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
    if (delete != true || !mounted) return;
    await ref.read(libraryRepositoryProvider).removeItem(widget.item.id);
    if (mounted) Navigator.of(context).pop();
  }
}

/// Choix de la conversation où repartager.
class _ConversationPicker extends ConsumerWidget {
  const _ConversationPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider) ?? '';
    final conversations = ref.watch(conversationsProvider);
    return SafeArea(
      child: conversations.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Erreur : $e'),
        ),
        data: (list) => list.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Aucune conversation où partager.'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (context, i) => ListTile(
                  title: Text(list[i].displayName(me)),
                  onTap: () => Navigator.pop(context, list[i].id),
                ),
              ),
      ),
    );
  }
}
