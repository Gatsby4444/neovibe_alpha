import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/content/content_preloader.dart';
import '../../core/content/content_view_reporter.dart';
import '../../core/crypto/media_open.dart';
import '../../core/models/card.dart';
import '../../core/theme.dart';
import '../../core/widgets/card_type_badge.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../../core/widgets/save_button.dart';
import '../../core/widgets/vibe_face.dart';
import '../../core/models/story.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../../core/video/video_open_trace.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/gradient.dart';
import '../cards/flippable_card.dart';
import '../conversations/conversations_repository.dart';
import '../library/user_library_screen.dart';
import 'stories_repository.dart';

/// Hauteur de l'en-tête sous la barre d'état : padding 8 + barres de
/// progression 2 + espace 10 + rangée d'icônes 48 + padding 8.
const _headerHeight = 76.0;

/// Visionneuse de stories : on avance d'une story à l'autre en tapant à
/// droite, on recule à gauche.
///
/// Depuis le 2026-08-13, elle parcourt **tous les anneaux du bandeau** et pas
/// seulement celui par lequel on est entré : arrivé au bout d'un auteur, le
/// clic à droite enchaîne sur le premier contenu du suivant. **On ne ferme
/// qu'au tout dernier contenu, ou par la croix** (consigne de Jay).
///
/// ⚠️ Depuis la refonte « 1 contenu = 1 format » (2026-08-11), cet écran ne
/// passe plus par `CardViewerScreen`. Une story n'est plus une Card : elle n'a
/// **ni livraison, ni limite de vues, ni budget de durée**. Faire transiter son
/// média par la machinerie des Cards imposait de neutraliser tout cela au cas
/// par cas — c'est exactement le mélange que la refonte supprime. Le chemin
/// média est donc ici, et il est court : scellé → clé → clair → affichage.
class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.rings,
    this.initialRing = 0,
  });

  /// **Tous** les anneaux du bandeau, dans l'ordre où ils y figurent — et non
  /// le seul anneau ouvert.
  ///
  /// C'est ce qui permet d'enchaîner d'un auteur au suivant sans repasser par
  /// le bandeau (consigne de Jay du 2026-08-13). Un appelant qui n'a qu'une
  /// story à montrer — le partage dans un fil de conversation — passe une
  /// liste d'**un** anneau : il n'y a alors pas de suivant, et la visionneuse
  /// se ferme au bout. Aucun cas particulier à écrire.
  final List<StoryRing> rings;

  /// L'anneau par lequel on entre.
  final int initialRing;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen> {
  late var _ringIndex = widget.initialRing;
  var _index = 0;
  var _showFront = true;

  StoryRing get _ring => widget.rings[_ringIndex];
  Story get _story => _ring.stories[_index];

  /// La position qui suit celle-ci, anneaux compris. Nulle au tout dernier
  /// contenu — c'est le seul endroit où « suivant » n'existe pas, et donc le
  /// seul où un clic à droite ferme l'écran.
  ///
  /// Un seul calcul pour DEUX usages : la navigation et le préchargement. Les
  /// écrire séparément, c'est se garantir qu'un jour l'un précharge ce que
  /// l'autre n'affichera pas.
  (int, int)? get _nextPosition {
    if (_index < _ring.stories.length - 1) return (_ringIndex, _index + 1);
    if (_ringIndex < widget.rings.length - 1) return (_ringIndex + 1, 0);
    return null;
  }

  /// La position qui précède, anneaux compris — symétrique de [_nextPosition].
  (int, int)? get _previousPosition {
    if (_index > 0) return (_ringIndex, _index - 1);
    if (_ringIndex > 0) {
      return (_ringIndex - 1, widget.rings[_ringIndex - 1].stories.length - 1);
    }
    return null;
  }

  /// Une face de la story affichée, en clair.
  ///
  /// Passe par le provider commun du socle : même cache, même chemin
  /// scellé → clé → clair, et le clair meurt avec le provider. Cet écran
  /// avait sa propre copie de cette logique — une de trop.
  ContentFace _spec(Story story, bool front) => (
    contentId: story.id,
    ownerId: story.ownerId,
    bucket: 'stories',
    path: front ? story.frontPath : story.backPath!,
    front: front,
    isVideo: front ? story.frontIsVideo : story.backIsVideo,
    encrypted: story.encrypted,
    batchOwner: null,
  );

  /// ⚠️ Capturés à l'initialisation. **`ref` est interdit dans `dispose()`** —
  /// le widget y est déjà démonté, et Riverpod lève « Using "ref" when a widget
  /// is about to or has been unmounted ». `card_viewer_screen.dart` porte cet
  /// avertissement depuis une panne antérieure ; la v0.9.64 l'a malgré tout
  /// reproduit ici, et le journal de Jay a relevé **19 occurrences** en une
  /// session de test.
  late final ContentViewReporter _reporter;
  late final ContentPreloader _preloader;

  @override
  void initState() {
    super.initState();
    _reporter = ref.read(contentViewReporterProvider);
    _preloader = ref.read(contentPreloaderProvider);
    // Le premier affichage n'a pas d'événement de changement de page : il faut
    // l'amorcer à la main, sinon la story d'ouverture ne serait ni comptée ni
    // suivie d'un préchargement.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStoryShown());
  }

  @override
  void dispose() {
    _reporter.stopped(_story.id);
    super.dispose();
  }

  /// Une story vient d'arriver à l'écran : on lance son compteur de vue et on
  /// prépare la suivante.
  void _onStoryShown() {
    if (!mounted) return;
    // La vue ne partira qu'après 3 s d'affichage réel (consigne de Jay du
    // 2026-08-13) : faire défiler des stories ne remplit plus le journal.
    _reporter.watching(_story.id);
    _preloadNext();
  }

  /// Prépare la story suivante — URL signée, clé et premier bloc.
  ///
  /// C'est le cas d'usage exact du préchargement : la suivante est connue
  /// d'avance et sera presque certainement regardée.
  ///
  /// ⚠️ Elle suit [_nextPosition], donc **elle franchit la frontière entre
  /// deux auteurs**. Depuis que le clic à droite enchaîne sur l'anneau suivant,
  /// la première story d'un auteur n'est plus une entrée à froid : s'arrêter au
  /// bord de l'anneau laisserait sans préparation précisément le contenu que
  /// l'utilisateur va voir.
  void _preloadNext() {
    final next = _nextPosition;
    if (next == null) return;
    final story = widget.rings[next.$1].stories[next.$2];
    _preloader.preload(_spec(story, true));
    // Le verso aussi : il s'affiche au retournement, et son coût serait alors
    // entièrement visible. Le préparer ne coûte rien de plus à l'utilisateur.
    if (story.hasBack) _preloader.preload(_spec(story, false));
  }

  void _goTo((int, int) position) {
    // La story quittée avant le seuil n'était pas un visionnage.
    _reporter.stopped(_story.id);
    setState(() {
      _ringIndex = position.$1;
      _index = position.$2;
      _showFront = true;
    });
    _onStoryShown();
  }

  /// Clic à droite. **On ne ferme qu'au tout dernier contenu** — au bord d'un
  /// anneau, on passe au premier contenu de l'auteur suivant (consigne de Jay
  /// du 2026-08-13). La croix, elle, ferme toujours.
  void _next() {
    final next = _nextPosition;
    next == null ? Navigator.of(context).pop() : _goTo(next);
  }

  /// Clic à gauche, symétrique : au premier contenu d'un anneau, on revient au
  /// DERNIER de l'auteur précédent. Sans cette symétrie, revenir sur ses pas
  /// après un enchaînement serait impossible — on ne pourrait plus que
  /// continuer ou fermer.
  void _previous() {
    final previous = _previousPosition;
    if (previous != null) _goTo(previous);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider);
    final owner = _ring.owner;
    final isMine = owner.id == me;
    final story = _story;
    final headerBottom = MediaQuery.paddingOf(context).top + _headerHeight;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        // ⚠️ TOUS les enfants sont `Positioned`. Un `Stack` se dimensionne sur
        // ses enfants NON positionnés ; l'en-tête était le seul, et le Stack
        // s'effondrait donc à sa hauteur (~100 px), écrasant et rognant la
        // Card en dessous. C'était la cause du « rien n'apparaît » de la
        // v0.9.40. Sans enfant non positionné, le Stack prend toute la place
        // que lui laisse le Scaffold.
        children: [
          Positioned.fill(
            child: Builder(
              key: ValueKey(story.id),
              builder: (context) {
                final front = ref.watch(
                  contentFaceProvider(_spec(story, true)),
                );
                // Demandé dès l'ouverture, affiché seulement au retournement :
                // c'est un préchargement, et la mesure doit le savoir (voir
                // [VideoOpenTrace.prefetched]).
                final back = story.hasBack
                    ? ref.watch(contentFaceProvider(_spec(story, false)))
                    : null;
                if (story.hasBack && story.backIsVideo) {
                  VideoOpenTrace.markPrefetched(story.id, front: false);
                }
                return front.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(color: Colors.white24),
                  ),
                  error: (e, _) => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "Cette story n'est plus disponible.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                  data: (frontFile) {
                    final frontFace = _face(
                      frontFile,
                      story.frontIsVideo,
                      story.cardType,
                      _showFront,
                    );
                    // ⚠️ La structure ne dépend QUE de `hasBack`, constant
                    // pendant toute la vie de l'écran — jamais de l'arrivée du
                    // verso. Choisir d'après `backFile == null` faisait changer
                    // le TYPE du widget à cette position, ce qui détruisait et
                    // reconstruisait le lecteur du recto (voir
                    // [VibeFaceLoading]).
                    if (!story.hasBack) {
                      return Center(child: TiltableCard(child: frontFace));
                    }
                    final backFile = back?.value;
                    return Center(
                      child: FlippableCard(
                        onSideChanged: (f) => setState(() => _showFront = f),
                        front: frontFace,
                        back: backFile == null
                            ? VibeFaceLoading(type: story.cardType)
                            : _face(
                                backFile,
                                story.backIsVideo,
                                story.cardType,
                                !_showFront,
                              ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Zones de navigation, sous l'en-tête pour ne pas manger ses taps.
          Positioned(
            top: headerBottom,
            left: 0,
            right: 0,
            bottom: 0,
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _previous,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _next,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _Header(
              ring: _ring,
              index: _index,
              story: story,
              isMine: isMine,
              // Les faces déchiffrées, s'il y en a : le bouton Enregistrer les
              // copie telles quelles.
              front: ref.watch(contentFaceProvider(_spec(story, true))).value,
              back: story.hasBack
                  ? ref.watch(contentFaceProvider(_spec(story, false))).value
                  : null,
              onClose: () => Navigator.of(context).pop(),
              onDelete: !isMine ? null : _confirmDelete,
              onShare: story.shareable ? _share : null,
              onStats: !isMine ? null : _showStats,
            ),
          ),
        ],
      ),
    );
  }

  /// Une story reste une Vibe : même cadre, même couleur de type, même halo.
  /// Seules les RÈGLES diffèrent (aucune limite de vues ni de durée), pas
  /// l'apparence.
  Widget _face(OpenedMedia m, bool isVideo, CardType type, bool active) =>
      isVideo
      ? VibeVideoFace(media: m, type: type, active: active)
      : VibePhotoFace(bytes: m.photoBytes!, type: type);

  Future<void> _confirmDelete() async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer cette story ?'),
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
    await ref.read(storiesRepositoryProvider).remove(_story.id);
    if (mounted) Navigator.of(context).pop();
  }

  /// Repartage dans une conversation. Aucun octet n'est copié : la story
  /// gagne des chemins d'accès, elle ne se duplique pas.
  Future<void> _share() async {
    final storyId = _story.id;
    final conversations = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => _ConversationPicker(),
    );
    if (conversations == null || !mounted) return;
    try {
      final added = await ref
          .read(storiesRepositoryProvider)
          .shareToConversation(storyId, conversations);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added == 0
                ? 'Déjà partagée dans cette conversation.'
                : 'Story partagée à $added personne${added > 1 ? 's' : ''}.',
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

  void _showStats() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => _StoryStatsSheet(storyId: _story.id),
    );
  }
}

/// Choix de la conversation où repartager.
class _ConversationPicker extends ConsumerWidget {
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
                itemBuilder: (context, i) {
                  final conv = list[i];
                  return ListTile(
                    title: Text(conv.displayName(me)),
                    onTap: () => Navigator.pop(context, conv.id),
                  );
                },
              ),
      ),
    );
  }
}

/// Statistiques d'une de MES stories.
///
/// Les spectateurs de mon cercle sont NOMMÉS ; ceux atteints par propagation
/// ne le sont pas — ils ne sont comptés que dans le total. Ce n'est pas une
/// limite technique : le serveur enregistre le nominatif dans tous les cas,
/// c'est l'affichage qui s'abstient (arbitrage de Jay, 2026-08-11 ; le détail
/// complet est réservé à la future option premium).
class _StoryStatsSheet extends ConsumerWidget {
  const _StoryStatsSheet({required this.storyId});
  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewers = ref.watch(storyViewersProvider(storyId));
    final total = ref.watch(storyViewerCountProvider(storyId)).value;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              total == null
                  ? 'Vues'
                  : 'Vue par $total personne${total > 1 ? 's' : ''}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: viewers.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Erreur : $e'),
              ),
              data: (list) {
                final beyond = (total ?? list.length) - list.length;
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final viewer in list)
                      ListTile(
                        leading: Avatar(stored: viewer.avatarUrl, radius: 18),
                        title: Text(
                          viewer.tagName ?? viewer.displayName ?? 'Quelqu\'un',
                        ),
                        trailing: Text(
                          shortTime(viewer.firstViewedAt),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    if (beyond > 0)
                      ListTile(
                        leading: const Icon(Icons.share_outlined),
                        title: Text(
                          'et $beyond personne${beyond > 1 ? 's' : ''} '
                          'hors de ton cercle',
                        ),
                        subtitle: const Text(
                          'atteintes par repartage',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    if (list.isEmpty && beyond == 0)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Personne ne l\'a encore vue.'),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// En-tête façon Instagram : barres de progression, avatar + pseudo cliquables
/// (consigne Jay 2026-08-02), horodatage, type, partage, statistiques,
/// suppression, fermeture.
///
/// Le bouton « Enregistrer » y est **revenu** à l'étape 5, sous la forme
/// décidée par Jay : une **copie locale** sur l'appareil, indépendante de son
/// auteur. Il n'apparaît que si celui-ci a coché « Sauvegardable ».
class _Header extends ConsumerWidget {
  const _Header({
    required this.ring,
    required this.index,
    required this.story,
    required this.isMine,
    this.front,
    this.back,
    required this.onClose,
    this.onDelete,
    this.onShare,
    this.onStats,
  });

  final StoryRing ring;
  final int index;
  final Story story;
  final bool isMine;
  final OpenedMedia? front;
  final OpenedMedia? back;
  final VoidCallback onClose;
  final VoidCallback? onDelete;
  final VoidCallback? onShare;
  final VoidCallback? onStats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ring.owner;

    return SafeArea(
      bottom: false,
      child: Container(
        height: _headerHeight,
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (var i = 0; i < ring.stories.length; i++)
                  Expanded(
                    child: Container(
                      height: 2,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      color: i <= index ? Colors.white : Colors.white24,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => UserLibraryScreen(profile: owner),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GradientRing(
                            size: 32,
                            thickness: 1.5,
                            child: AvatarFill(
                              stored: owner.avatarUrl,
                              fallback: Container(
                                // La visionneuse reste sombre dans les deux
                                // thèmes : gris fixe, mais neutre.
                                color: NeoNeutrals.gray700,
                                alignment: Alignment.center,
                                child: Text(
                                  owner.chatName.characters.first.toUpperCase(),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              owner.chatName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    shortTime(story.createdAt),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const Spacer(),
                  CardTypeBadge(type: story.cardType, fontSize: 11),
                  const SizedBox(width: 4),
                  SaveButton(
                    contentId: story.id,
                    cardType: story.cardType,
                    canSave: story.saveable || isMine,
                    front: front,
                    back: back,
                    frontIsVideo: story.frontIsVideo,
                    backIsVideo: story.backIsVideo,
                    mine: isMine,
                  ),
                  if (onStats != null)
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.visibility_outlined),
                      tooltip: 'Qui a vu',
                      onPressed: onStats,
                    ),
                  if (onShare != null)
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.reply_outlined),
                      tooltip: 'Partager dans une conversation',
                      onPressed: onShare,
                    ),
                  if (onDelete != null)
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Retirer cette story',
                      onPressed: onDelete,
                    ),
                  // Signaler / bloquer : jamais sur sa propre story.
                  if (!isMine)
                    ContentOverflowMenu(
                      contentId: story.id,
                      authorId: story.ownerId,
                      authorName: owner.chatName,
                    ),
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
