import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_view_reporter.dart';
import '../../../core/content/likes.dart';
import '../../../core/models/library_item.dart';
import '../../../core/models/profile.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/utils/formats.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/card_type_badge.dart';
import '../../../core/widgets/pull_down_to_close.dart';
import '../../connections/connections_repository.dart';
import '../user_library_screen.dart';
import 'publication_actions.dart';
import 'vibe_card_view.dart';

/// **Les Vibes en plein écran, à la suite** — façon Reels : une Vibe par
/// écran, fond noir, on glisse vers le haut pour la suivante. La carte se
/// retourne au doigt (horizontal) ; le geste vertical appartient au
/// défilement. Par-dessus : l'auteur et la légende en bas à gauche, les
/// actions en colonne à droite, la croix en haut.
///
/// Fermer : la croix, ou **tirer vers le bas depuis la première Vibe** —
/// le même geste que les autres visionneurs (Jay, 2026-09-14), lu ici dans
/// le sur-défilement que la liste rapporte, puisque c'est elle qui tient le
/// doigt (voir [_OverscrollToClose]).
///
/// Même écran demain pour le feed des Vibes : seule la liste change.
class VibesReelScreen extends ConsumerStatefulWidget {
  const VibesReelScreen({
    super.key,
    required this.vibes,
    required this.initialIndex,
  });

  final List<LibraryItem> vibes;
  final int initialIndex;

  @override
  ConsumerState<VibesReelScreen> createState() => _VibesReelScreenState();
}

class _VibesReelScreenState extends ConsumerState<VibesReelScreen> {
  late List<LibraryItem> _vibes = List.of(widget.vibes);
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
      ref.read(likesStoreProvider.notifier).load(_vibes.map((v) => v.id));
      // La vue ne part qu'après 3 s d'affichage réel (Jay, 2026-08-13).
      _reporter.watching(_vibes[_current].id);
    });
  }

  @override
  void dispose() {
    if (_current < _vibes.length) _reporter.stopped(_vibes[_current].id);
    _pages.dispose();
    super.dispose();
  }

  void _onPage(int i) {
    if (_current < _vibes.length) _reporter.stopped(_vibes[_current].id);
    setState(() => _current = i);
    _reporter.watching(_vibes[i].id);
  }

  void _removed(LibraryItem item) {
    _reporter.stopped(item.id);
    final rest = _vibes.where((v) => v.id != item.id).toList();
    if (rest.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _vibes = rest;
      _current = _current.clamp(0, rest.length - 1);
    });
    _reporter.watching(_vibes[_current].id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _OverscrollToClose(
        atFirstPage: _current == 0,
        onClose: () => Navigator.of(context).maybePop(),
        child: Stack(
          children: [
            // Sans la lueur de bord : le sur-défilement du haut est un
            // geste (fermer), pas une butée à signaler.
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(overscroll: false),
              child: PageView.builder(
                controller: _pages,
                scrollDirection: Axis.vertical,
                onPageChanged: _onPage,
                itemCount: _vibes.length,
                itemBuilder: (context, i) => _ReelPage(
                  key: ValueKey(_vibes[i].id),
                  item: _vibes[i],
                  active: i == _current,
                  onDeleted: () => _removed(_vibes[i]),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close),
                  color: Colors.white,
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une Vibe et ce qui flotte dessus. Les faces sont ouvertes ici aussi
/// (même provider que [VibeCardView], donc même cache) pour « Enregistrer ».
class _ReelPage extends ConsumerWidget {
  const _ReelPage({
    super.key,
    required this.item,
    required this.active,
    required this.onDeleted,
  });

  final LibraryItem item;
  final bool active;
  final VoidCallback onDeleted;

  ContentFace _spec(bool front) => (
    contentId: item.id,
    ownerId: item.ownerId,
    bucket: 'library',
    path: front ? item.frontPath : item.backPath!,
    slot: front ? ContentSlot.front : ContentSlot.back,
    isVideo: front ? item.frontIsVideo : item.backIsVideo,
    encrypted: item.encrypted,
    batchOwner: item.ownerId,
    expiresAt: null,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = item.ownerId == ref.watch(currentUserIdProvider);
    final owner = ref.watch(profileByIdProvider(item.ownerId)).value;
    final front = ref.watch(contentFaceProvider(_spec(true))).value;
    final back = item.hasBack
        ? ref.watch(contentFaceProvider(_spec(false))).value
        : null;

    return Stack(
      fit: StackFit.expand,
      children: [
        // La carte, centrée, avec de l'air en bas pour la légende.
        Padding(
          padding: const EdgeInsets.only(bottom: 56),
          child: Center(
            child: VibeCardView(item: item, active: active, fullScreen: true),
          ),
        ),
        // Le voile du bas : lisibilité du texte, sans cacher la carte.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              height: 220,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 64,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NeoSpace.lg,
                0,
                0,
                NeoSpace.md,
              ),
              child: _Author(item: item, owner: owner, mine: mine),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(right: 4, bottom: NeoSpace.sm),
              child: PublicationActions(
                item: item,
                mine: mine,
                saveId: item.id,
                saveFront: front,
                saveBack: back,
                saveFrontIsVideo: item.frontIsVideo,
                saveBackIsVideo: item.backIsVideo,
                vertical: true,
                color: Colors.white,
                onDeleted: onDeleted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// L'auteur (avatar, nom, âge, type) et la légende — dépliable au tap.
class _Author extends StatefulWidget {
  const _Author({required this.item, required this.owner, required this.mine});

  final LibraryItem item;
  final Profile? owner;
  final bool mine;

  @override
  State<_Author> createState() => _AuthorState();
}

class _AuthorState extends State<_Author> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final owner = widget.owner;
    final name = owner?.displayName ?? '';
    final caption = widget.item.caption;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: owner == null || widget.mine
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => UserLibraryScreen(profile: owner),
                  ),
                ),
          child: Row(
            children: [
              Avatar(
                stored: owner?.avatarUrl,
                radius: 16,
                fallback: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
              ),
              const SizedBox(width: NeoSpace.sm),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: NeoSpace.sm),
              Text(
                timeAgo(widget.item.createdAt),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(width: NeoSpace.sm),
              CardTypeBadge(type: widget.item.cardType, fontSize: 10),
            ],
          ),
        ),
        if (caption != null && caption.isNotEmpty) ...[
          const SizedBox(height: NeoSpace.xs),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              caption,
              maxLines: _expanded ? 12 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ],
    );
  }
}

/// **Tirer vers le bas depuis la première page ferme.** Ici la liste tient
/// le geste vertical (c'est le défilement) : on ne peut pas poser un second
/// reconnaisseur par-dessus, il perdrait toujours. On lit donc ce que la
/// liste rapporte quand elle bute en haut — le sur-défilement — et on
/// applique la **même décision** et la **même animation** que
/// [PullDownToClose] (seuil, vitesse, échelle).
class _OverscrollToClose extends StatefulWidget {
  const _OverscrollToClose({
    required this.atFirstPage,
    required this.onClose,
    required this.child,
  });

  final bool atFirstPage;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<_OverscrollToClose> createState() => _OverscrollToCloseState();
}

class _OverscrollToCloseState extends State<_OverscrollToClose>
    with SingleTickerProviderStateMixin {
  var _drag = 0.0;
  var _closing = false;
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() => _drag = _tween.evaluate(_anim)));
  var _tween = Tween<double>(begin: 0, end: 0);

  bool _onNotification(ScrollNotification n) {
    if (_closing || !widget.atFirstPage) return false;
    if (n is OverscrollNotification && n.overscroll < 0) {
      // Le doigt tire vers le bas alors qu'on est déjà en haut.
      _anim.stop();
      setState(() => _drag -= n.overscroll);
    } else if (n is ScrollEndNotification && _drag > 0) {
      final height = context.size?.height ?? 800;
      final velocity = n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0;
      final ferme = PullDownToClose.shouldClose(
        drag: _drag,
        velocity: velocity,
        height: height,
      );
      if (ferme) {
        _closing = true;
        _animateTo(height).whenComplete(() {
          if (mounted) widget.onClose();
        });
      } else {
        _animateTo(0);
      }
    }
    return false;
  }

  TickerFuture _animateTo(double cible) {
    _tween = Tween(begin: _drag, end: cible);
    return _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final scale = PullDownToClose.scaleFor(drag: _drag, height: height);
    final t = (_drag / (height * PullDownToClose.distancePleineEchelle)).clamp(
      0.0,
      1.0,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: ColoredBox(
        color: Color.lerp(Colors.black, context.palette.ground, t)!,
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topCenter,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
