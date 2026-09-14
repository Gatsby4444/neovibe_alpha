import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/content/content_repost.dart';
import '../../core/content/content_view_reporter.dart';
import '../../core/crypto/media_open.dart';
import '../../core/models/card.dart';
import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/video/sealed_video_controller.dart';
import '../../core/video/sealed_video_view.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../../core/widgets/pull_down_to_close.dart';
import '../../core/widgets/save_button.dart';
import '../../core/widgets/vibe_face.dart';
import '../cards/send/recipient_picker_screen.dart';
import '../cards/send/share_context.dart';
import '../cards/send/share_plan.dart';
import 'library_repository.dart';

/// Lecture plein écran d'un **album** — une publication qu'on feuillette.
///
/// C'est le seul endroit où le format d'un album se voit : dans la grille il
/// occupe la même case qu'une Card (consigne de Jay, 2026-09-15 : *« c'est
/// juste le viewer qui changera quand elles seront ouvertes »*). Ici : le
/// ratio commun de la publication, un média par page à l'horizontale, les
/// points, la légende. Les actions sont celles de `PublicationViewerScreen`
/// (enregistrer, repartager, retirer, signaler) — mêmes règles, même contenu.
class AlbumViewerScreen extends ConsumerStatefulWidget {
  const AlbumViewerScreen({
    super.key,
    required this.item,
    this.initialSlot = 0,
  });

  final LibraryItem item;
  final int initialSlot;

  @override
  ConsumerState<AlbumViewerScreen> createState() => _AlbumViewerScreenState();
}

class _AlbumViewerScreenState extends ConsumerState<AlbumViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initialSlot,
  );
  late int _current = widget.initialSlot;

  /// ⚠️ Capturé à l'initialisation : `ref` est interdit dans `dispose()`.
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
    _pages.dispose();
    super.dispose();
  }

  ContentFace _spec(LibraryMedia m) => (
    contentId: widget.item.id,
    ownerId: widget.item.ownerId,
    bucket: 'library',
    path: m.path,
    slot: m.slot,
    isVideo: m.isVideo,
    encrypted: widget.item.encrypted,
    // Un contenu isolé : un appel de clé suffit, pas de lot à charger.
    batchOwner: null,
    // Permanente (décision de Jay, 2026-08-11) : rien à faire expirer.
    expiresAt: null,
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final media = item.media;
    final mine = item.ownerId == ref.watch(currentUserIdProvider);
    final current = media[_current];
    final opened = ref.watch(contentFaceProvider(_spec(current)));
    // Le média suivant est demandé d'avance : feuilleter ne doit pas attendre.
    if (_current + 1 < media.length) {
      ref.watch(contentFaceProvider(_spec(media[_current + 1])));
    }

    return PullDownToClose(
      onClose: () => Navigator.of(context).maybePop(),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: media.length > 1
              ? Text(
                  '${_current + 1} / ${media.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                )
              : null,
          actions: [
            // Enregistrer : le média affiché, en clair sur l'appareil. Chaque
            // média d'un album est un enregistrement à part (clé locale
            // composée : rien d'autre ne lit cet identifiant).
            SaveButton(
              contentId: '${item.id}#${current.slot}',
              cardType: CardType.standard,
              canSave: item.saveable || mine,
              front: opened.value,
              frontIsVideo: current.isVideo,
              mine: mine,
            ),
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
            if (!mine)
              ContentOverflowMenu(contentId: item.id, authorId: item.ownerId),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: (item.aspect ?? AlbumAspect.portrait).ratio,
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: media.length,
                    onPageChanged: (i) => setState(() => _current = i),
                    itemBuilder: (context, i) => _AlbumPage(
                      spec: _spec(media[i]),
                      isVideo: media[i].isVideo,
                      active: i == _current,
                    ),
                  ),
                ),
              ),
            ),
            if (media.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _Dots(count: media.length, current: _current),
              ),
            if (item.caption != null && item.caption!.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Text(
                    item.caption!,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else
              const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _share() async {
    // Le même écran « À qui ? » que la capture, en mode repartage.
    final plan = await Navigator.of(context).push<SharePlan>(
      MaterialPageRoute(
        builder: (_) => RecipientPickerScreen(
          shareContext: RepostShareContext(
            contentId: widget.item.id,
            what: 'publication',
          ),
        ),
      ),
    );
    if (plan == null || !mounted) return;
    try {
      final resultat = await ref
          .read(contentRepostProvider)
          .toPlan(widget.item.id, plan);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(resultat)));
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
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(libraryRepositoryProvider).removeItem(widget.item.id);
    } catch (_) {
      // Fermer, c'est dire que c'est fait : on ne ferme pas sur un échec.
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Impossible de retirer cette publication.'),
        ),
      );
      return;
    }
    navigator.pop();
  }
}

/// Une page de l'album : la photo, ou la vidéo qui joue quand elle est
/// affichée et se tait dès qu'on la quitte.
class _AlbumPage extends ConsumerWidget {
  const _AlbumPage({
    required this.spec,
    required this.isVideo,
    required this.active,
  });

  final ContentFace spec;
  final bool isVideo;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opened = ref.watch(contentFaceProvider(spec));
    return opened.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(color: Colors.white24)),
      error: (e, _) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Ce média n\'est plus disponible.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      ),
      data: (media) => isVideo
          ? _AlbumVideo(media: media, active: active)
          : Image.memory(
              media.photoBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
    );
  }
}

/// La vidéo d'une page : le lecteur natif scellé, en boucle, au son quand la
/// page est affichée ; un tap met en pause et relance.
///
/// Distincte de `VibeVideoFace` : pas de cadre de Card, pas de ratio 9:16 —
/// l'album impose le sien.
class _AlbumVideo extends StatefulWidget {
  const _AlbumVideo({required this.media, required this.active});

  final OpenedMedia media;
  final bool active;

  @override
  State<_AlbumVideo> createState() => _AlbumVideoState();
}

class _AlbumVideoState extends State<_AlbumVideo> {
  late final SealedVideoController _controller = widget.media.videoController();
  Object? _error;
  var _paused = false;

  @override
  void initState() {
    super.initState();
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          _controller.setLooping(true);
          _controller.setVolume(widget.active ? 1 : 0);
          if (widget.active) _controller.play();
          setState(() {});
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  @override
  void didUpdateWidget(covariant _AlbumVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_controller.value.isInitialized) return;
    _controller.setVolume(widget.active ? 1 : 0);
    if (widget.active && !_paused) {
      _controller.play();
    } else {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_controller.value.isInitialized) return;
    setState(() => _paused = !_paused);
    _paused ? _controller.pause() : _controller.play();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return VideoFaceError(error: _error!);
    if (!_controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white24),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: SealedVideoView(_controller),
            ),
          ),
          if (_paused)
            const Center(
              child: Icon(
                Icons.play_arrow_rounded,
                size: 72,
                color: Colors.white70,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SealedVideoProgressBar(
              controller: _controller,
              allowScrubbing: true,
              playedColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Les points sous le carrousel : le courant en plein, les autres estompés.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == current ? 7 : 5,
            height: i == current ? 7 : 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i == current ? Colors.white : Colors.white30,
            ),
          ),
      ],
    );
  }
}
