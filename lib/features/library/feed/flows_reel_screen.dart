import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_view_reporter.dart';
import '../../../core/content/likes.dart';
import '../../../core/crypto/media_open.dart';
import '../../../core/models/library_item.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/typography.dart';
import '../../../core/video/sealed_video_controller.dart';
import '../../../core/video/sealed_video_view.dart';
import '../../../core/video/video_watchdog.dart';
import '../../../core/widgets/action_button.dart';
import '../../../core/widgets/anchor_scope.dart';
import '../../../core/widgets/like_burst.dart';
import '../../../core/widgets/pinch_to_close.dart';
import '../../../core/widgets/system_bars.dart';
import '../../../core/widgets/vibe_face.dart';
import '../../connections/connections_repository.dart';
import 'flow_frame.dart';
import 'publication_actions.dart';
import 'reel_common.dart';

/// **Les Flows en plein écran, à la suite** — façon Reels (Jay, 2026-09-17 :
/// *« lorsqu'elles sont cliquées depuis le fil, tu crées un mode plein écran
/// comme sur Insta avec les reels »*).
///
/// Une vidéo par écran, fond noir, on glisse vers le haut pour la suivante.
/// Par-dessus, **dans le cadre de la vidéo** ([FlowFrame]) : l'auteur en
/// haut à gauche, la légende en bas ; et les actions en colonne à droite,
/// le cœur **au milieu de l'écran** (Jay, 2026-09-20).
///
/// ⚠️ **Ce n'est pas l'écran des Vibes, et c'est voulu.** Une Vibe est un
/// objet qu'on manipule — elle se retourne, elle s'incline, son habillage vit
/// *dans* la carte. Un Flow est une vidéo : elle remplit l'écran, et ce qui
/// se pose dessus flotte au-dessus. Les deux écrans partagent ce qui est
/// commun ([ReelIdentity], [ReelCaption], [OverscrollToClose]) et rien de
/// plus.
///
/// ⚠️ **Un seul lecteur vit à la fois** : seule la page regardée ouvre le
/// sien. Un décodeur vidéo est une ressource matérielle comptée — c'est ce
/// qui rendait des vidéos noires avec le son (v0.9.197).
class FlowsReelScreen extends ConsumerStatefulWidget {
  const FlowsReelScreen({
    super.key,
    required this.flows,
    required this.initialIndex,
    this.anchors,
    this.header,
  });

  /// **Posé sur la vidéo, à gauche de la croix** (le sélecteur d'un fil de
  /// Pulse) — **sans bande** : la vidéo garde tout l'écran, et l'auteur d'un
  /// Flow descend sous cette ligne (Jay, 2026-09-20 : *« comme si les
  /// boutons étaient par-dessus l'écran, pas de container bandeau »*). Nul =
  /// rien, l'écran du profil.
  final Widget? header;

  final List<LibraryItem> flows;
  final int initialIndex;

  /// Le registre de positions de l'écran qui nous a ouverts : c'est sur sa
  /// cellule que la rétraction se referme, et c'est à lui qu'on demande de
  /// suivre (voir [AnchorScope]). Nul = rétraction au centre.
  final AnchorScopeState? anchors;

  @override
  ConsumerState<FlowsReelScreen> createState() => _FlowsReelScreenState();
}

class _FlowsReelScreenState extends ConsumerState<FlowsReelScreen> {
  late List<LibraryItem> _flows = List.of(widget.flows);
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  /// ⚠️ Capturé à l'initialisation : `ref` est interdit dans `dispose()`.
  late final ContentViewReporter _reporter;

  @override
  void initState() {
    super.initState();
    _reporter = ref.read(contentViewReporterProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(likesStoreProvider.notifier).load(_flows.map((f) => f.id));
      _reporter.watching(_flows[_current].id);
    });
  }

  @override
  void dispose() {
    if (_current < _flows.length) _reporter.stopped(_flows[_current].id);
    _pages.dispose();
    super.dispose();
  }

  void _onPage(int i) {
    if (_current < _flows.length) _reporter.stopped(_flows[_current].id);
    setState(() => _current = i);
    _reporter.watching(_flows[i].id);
  }

  void _removed(LibraryItem item) {
    _reporter.stopped(item.id);
    final reste = _flows.where((f) => f.id != item.id).toList();
    if (reste.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _flows = reste;
      _current = _current.clamp(0, reste.length - 1);
    });
    if (_pages.hasClients && _pages.page?.round() != _current) {
      _pages.jumpToPage(_current);
    }
    _reporter.watching(_flows[_current].id);
  }

  /// La légende d'un Flow a changé : on remplace l'exemplaire qu'on tient.
  void _changed(LibraryItem item) {
    final index = _flows.indexWhere((f) => f.id == item.id);
    if (index < 0) return;
    setState(() => _flows = List.of(_flows)..[index] = item);
  }

  /// Les pages, verticales — le même bloc avec ou sans bandeau.
  Widget _pageView(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: PageView.builder(
        controller: _pages,
        scrollDirection: Axis.vertical,
        onPageChanged: _onPage,
        itemCount: _flows.length,
        itemBuilder: (context, i) => _FlowPage(
          key: ValueKey(_flows[i].id),
          item: _flows[i],
          active: i == _current,
          topLine: widget.header != null,
          onDeleted: () => _removed(_flows[i]),
          onChanged: _changed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DarkSystemBars(
      // Transparent : la route est une superposition (voir [ReelRoute]), le
      // noir est DANS ce qui se rétracte — autour de l'heptagone, le profil.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: PinchToClose(
          onClose: () => Navigator.of(context).maybePop(),
          // Dès que le pincement commence, le dessous se pose sur ce qu'on
          // regarde ; puis la forme vise cette cellule, image après image.
          onStart: () => widget.anchors?.reveal(_flows[_current].id),
          target: () => widget.anchors?.rectOf(_flows[_current].id),
          child: OverscrollToClose(
            atFirstPage: _current == 0,
            onClose: () => Navigator.of(context).maybePop(),
            child: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                _pageView(context),
                // La ligne du haut, posée SUR la vidéo : le sélecteur s'il y
                // en a un, puis la croix, alignés à droite.
                Positioned(
                  top: 0,
                  right: 0,
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: kToolbarHeight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ?widget.header,
                          IconButton(
                            icon: const Icon(Icons.close),
                            color: Colors.white,
                            tooltip: 'Fermer',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Un Flow et ce qui flotte dessus.
class _FlowPage extends ConsumerStatefulWidget {
  const _FlowPage({
    super.key,
    required this.item,
    required this.active,
    required this.topLine,
    required this.onDeleted,
    required this.onChanged,
  });

  final LibraryItem item;
  final bool active;

  /// Une ligne de boutons flotte en haut de l'écran (le sélecteur de Pulse) :
  /// l'auteur descend dessous.
  final bool topLine;
  final VoidCallback onDeleted;
  final ValueChanged<LibraryItem> onChanged;

  @override
  ConsumerState<_FlowPage> createState() => _FlowPageState();
}

class _FlowPageState extends ConsumerState<_FlowPage> {
  /// La taille réelle de la vidéo, publiée par le lecteur une fois ouvert.
  /// Avant : le format enregistré à la publication ; à défaut, 9:16.
  Size? _videoSize;

  LibraryItem get item => widget.item;

  double get _ratio {
    final v = _videoSize;
    if (v != null && !v.isEmpty) return v.width / v.height;
    return item.aspect?.ratio ?? AlbumAspect.reel.ratio;
  }

  ContentFace get _spec => (
    contentId: item.id,
    ownerId: item.ownerId,
    bucket: 'library',
    path: item.media.first.path,
    slot: item.media.first.slot,
    isVideo: true,
    encrypted: item.encrypted,
    batchOwner: item.ownerId,
    expiresAt: null,
  );

  void _onSize(Size size) {
    if (size == _videoSize || !mounted) return;
    setState(() => _videoSize = size);
  }

  @override
  Widget build(BuildContext context) {
    final mine = item.ownerId == ref.watch(currentUserIdProvider);
    final owner = ref.watch(profileByIdProvider(item.ownerId)).value;
    final ouvert = ref.watch(contentFaceProvider(_spec));
    final caption = item.caption;
    final hasCaption = caption != null && caption.isNotEmpty;
    final safe = MediaQuery.paddingOf(context);
    final screenHeight = MediaQuery.sizeOf(context).height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final page = constraints.biggest;
        final rect = FlowFrame.rectFor(ratio: _ratio, page: page);
        // Ce que le haut de la vidéo rend : l'encoche, et la ligne de
        // boutons quand elle est là.
        final top = FlowFrame.topInset(
          rect: rect,
          safeTop: safe.top + (widget.topLine ? kToolbarHeight : 0),
        );
        final bottom = FlowFrame.bottomInset(
          rect: rect,
          page: page,
          safeBottom: safe.bottom,
        );
        final close = FlowFrame.closeReserve(
          rect: rect,
          page: page,
          safeTop: safe.top,
          authorTop: rect.top + top,
        );
        final heart = FlowFrame.heartCenter(
          page: page,
          screenHeight: screenHeight,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            // La vidéo, plein cadre. Aimer au geste, comme dans le fil.
            LikeBurst(
              contentId: item.id,
              doubleTap: true,
              child: ouvert.when(
                loading: () => const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white24),
                  ),
                ),
                error: (e, _) => ColoredBox(
                  color: Colors.black,
                  child: VideoFaceError(error: e),
                ),
                data: (media) => _Video(
                  media: media,
                  active: widget.active,
                  onSize: _onSize,
                ),
              ),
            ),
            // **Dans le cadre de la vidéo** : les voiles, l'auteur en haut,
            // la légende en bas (Jay, 2026-09-20 : « il doit être dans le
            // contenu en plein écran » ; « la description en bas du
            // contenu »). La droite du haut est laissée au bouton « Fermer »
            // quand la vidéo monte jusqu'à lui ; celle du bas, à la colonne
            // d'actions.
            Positioned.fromRect(
              rect: rect,
              child: Stack(
                children: [
                  // Les voiles : du blanc sur une vidéo claire ne se lit pas.
                  const _Veil(top: true),
                  if (hasCaption) const _Veil(top: false),
                  Positioned(
                    left: NeoSpace.lg,
                    right: close > NeoSpace.lg ? close : NeoSpace.lg,
                    top: top + NeoSpace.sm,
                    child: ReelIdentity(item: item, owner: owner, mine: mine),
                  ),
                  if (hasCaption)
                    Positioned(
                      left: NeoSpace.lg,
                      right: _kActionsReserve,
                      bottom: bottom + NeoSpace.md,
                      child: ReelCaption(text: caption),
                    ),
                ],
              ),
            ),
            // La colonne d'actions : à droite, le cœur centré sur le milieu
            // de l'écran, le reste dessous.
            Positioned(
              right: _kActionsRight,
              top: heart - ActionMetrics.extent(false) / 2,
              child: PublicationActions(
                item: item,
                mine: mine,
                saveId: item.id,
                saveFront: ouvert.value,
                saveFrontIsVideo: true,
                vertical: true,
                color: Colors.white,
                onDeleted: widget.onDeleted,
                onChanged: widget.onChanged,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// La marge de la colonne d'actions au bord droit, et la largeur que la
/// légende lui laisse (un bouton plein + cette marge + un écart).
const _kActionsRight = 10.0;
const _kActionsReserve = 48.0 + _kActionsRight + NeoSpace.sm;

/// Un voile noir dégradé sur un bord de la vidéo, pour que le blanc se lise.
class _Veil extends StatelessWidget {
  const _Veil({required this.top});

  final bool top;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: top ? 0 : null,
    bottom: top ? null : 0,
    child: IgnorePointer(
      child: SizedBox(
        height: 160,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: const [Color(0xB3000000), Colors.transparent],
            ),
          ),
        ),
      ),
    ),
  );
}

/// La vidéo d'un Flow : elle remplit l'écran, en boucle, avec le son.
class _Video extends StatefulWidget {
  const _Video({
    required this.media,
    required this.active,
    required this.onSize,
  });

  final OpenedMedia media;
  final bool active;

  /// La taille de la vidéo, une fois connue : c'est elle qui donne le cadre
  /// à ce qui se pose dessus ([FlowFrame]).
  final ValueChanged<Size> onSize;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  late final SealedVideoController _controller = widget.media.videoController();
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onValeur);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          _controller.setLooping(true);
          _apply();
          setState(() {});
          widget.onSize(_controller.value.size);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  /// Un décodeur peut mourir en route : le son continue, l'image devient
  /// noire. Ça doit se voir (v0.9.197).
  void _onValeur() {
    final e = _controller.value.error;
    if (e != null && _error == null && mounted) setState(() => _error = e);
  }

  void _apply() {
    if (!_controller.value.isInitialized) return;
    _controller.setVolume(widget.active ? 1 : 0);
    widget.active ? _controller.play() : _controller.pause();
  }

  @override
  void didUpdateWidget(covariant _Video old) {
    super.didUpdateWidget(old);
    _apply();
  }

  @override
  void dispose() {
    _controller.removeListener(_onValeur);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: VideoFaceError(error: _error!),
      );
    }
    if (!_controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white24)),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: VideoWatchdog(
        controller: _controller,
        child: FittedBox(
          // `contain` : un Flow est publié à SON format (choix de Jay), il ne
          // se recadre pas pour remplir un écran 9:16 — les bandes noires font
          // partie du format, comme chez Instagram.
          fit: BoxFit.contain,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _controller.value.size.width,
            height: _controller.value.size.height,
            child: SealedVideoView(_controller),
          ),
        ),
      ),
    );
  }
}
