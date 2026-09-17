import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/crypto/media_open.dart';
import '../../../core/models/library_item.dart';
import '../../../core/video/sealed_video_controller.dart';
import '../../../core/video/sealed_video_view.dart';
import '../../../core/video/video_watchdog.dart';
import '../../../core/widgets/vibe_face.dart';

/// **Le carrousel d'un album** : ses médias à son ratio, feuilletés à
/// l'horizontale, les points, une vidéo qui joue quand la page est visible
/// et que la cellule est active — muette d'abord, un tap pour le son (comme
/// dans un fil). Même composant dans le fil du profil et, demain, dans le
/// feed.
class AlbumCarousel extends ConsumerStatefulWidget {
  const AlbumCarousel({
    super.key,
    required this.item,
    required this.active,
    this.onPageChanged,
    this.initialPage = 0,
  });

  final LibraryItem item;

  /// La cellule est celle qu'on regarde : ses vidéos peuvent jouer.
  final bool active;
  final ValueChanged<int>? onPageChanged;
  final int initialPage;

  @override
  ConsumerState<AlbumCarousel> createState() => _AlbumCarouselState();
}

class _AlbumCarouselState extends ConsumerState<AlbumCarousel> {
  late final PageController _pages = PageController(
    initialPage: widget.initialPage,
  );
  late int _current = widget.initialPage;
  var _muted = true;

  @override
  void dispose() {
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
    // Un fil : les clés viennent du lot de la bibliothèque, une par
    // propriétaire, pas une par média.
    batchOwner: widget.item.ownerId,
    expiresAt: null,
  );

  /// La couverture d'une vidéo, s'il y en a une : la même clé, la même
  /// place de cache que le poster déposé à la publication.
  ContentFace? _posterSpec(LibraryMedia m) {
    final poster = m.posterPath;
    if (!m.isVideo || poster == null) return null;
    return (
      contentId: widget.item.id,
      ownerId: widget.item.ownerId,
      bucket: 'library',
      path: poster,
      slot: ContentSlot.poster(m.slot),
      isVideo: false,
      encrypted: widget.item.encrypted,
      batchOwner: widget.item.ownerId,
      expiresAt: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final media = item.media;
    // Le média suivant est demandé d'avance : feuilleter ne doit pas attendre.
    if (_current + 1 < media.length) {
      ref.watch(contentFaceProvider(_spec(media[_current + 1])));
    }
    // Dans le fil, rien n'est plus haut que 4:5 : un Flow en 9:16 s'y
    // recadre comme une Vibe (Jay : « dans le fil pas de bandes noires, le
    // fil s'adapte au format de la vidéo »). Son plein écran, lui, montre
    // tout.
    final ratio = (item.aspect ?? AlbumAspect.portrait).ratio;
    return AspectRatio(
      aspectRatio: math.max(ratio, kVibeFeedRatio),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          PageView.builder(
            controller: _pages,
            itemCount: media.length,
            onPageChanged: (i) {
              setState(() => _current = i);
              widget.onPageChanged?.call(i);
            },
            itemBuilder: (context, i) => _Page(
              spec: _spec(media[i]),
              // La couverture d'une vidéo : ce qu'on montre quand son
              // lecteur n'existe pas.
              poster: _posterSpec(media[i]),
              isVideo: media[i].isVideo,
              playing: widget.active && i == _current,
              muted: _muted,
              onToggleMute: () => setState(() => _muted = !_muted),
            ),
          ),
          if (media.length > 1)
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_current + 1}/${media.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          if (media.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Dots(count: media.length, current: _current),
            ),
        ],
      ),
    );
  }
}

/// Les points sous un carrousel : le courant en plein, les autres estompés.
class Dots extends StatelessWidget {
  const Dots({super.key, required this.count, required this.current});

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
              color: i == current ? Colors.white : Colors.white54,
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 2),
              ],
            ),
          ),
      ],
    );
  }
}

/// Une page du carrousel.
///
/// ⚠️ **Un lecteur vidéo n'est créé que pour la page qu'on REGARDE.**
/// Jusqu'au 2026-09-17, chaque page construite par le `PageView` — donc les
/// voisines aussi — ouvrait le sien. Un lecteur, c'est un décodeur matériel,
/// et un téléphone en a un nombre fini : passé la limite, le décodeur vidéo
/// échoue **pendant que le son continue**. C'est l'écran noir de Jay.
/// Les autres pages montrent leur couverture, qui est une image.
class _Page extends ConsumerWidget {
  const _Page({
    required this.spec,
    required this.poster,
    required this.isVideo,
    required this.playing,
    required this.muted,
    required this.onToggleMute,
  });

  final ContentFace spec;

  /// La couverture, si c'est une vidéo qui en a une.
  final ContentFace? poster;
  final bool isVideo;
  final bool playing;
  final bool muted;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Une vidéo qu'on ne regarde pas : sa couverture, et rien d'autre.
    if (isVideo && !playing && poster != null) {
      final couverture = ref.watch(contentFaceProvider(poster!));
      return couverture.when(
        loading: () => const ColoredBox(color: Colors.black),
        error: (e, _) => const ColoredBox(color: Colors.black),
        data: (m) => Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              m.photoBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
            const Center(
              child: Icon(
                Icons.play_circle_outline,
                color: Colors.white70,
                size: 46,
              ),
            ),
          ],
        ),
      );
    }
    final opened = ref.watch(contentFaceProvider(spec));
    return opened.when(
      loading: () => const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            color: Colors.white38,
            strokeWidth: 2,
          ),
        ),
      ),
      error: (e, _) => const Center(
        child: Text(
          'Ce média n\'est plus disponible.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      ),
      data: (media) => isVideo
          ? _Video(
              media: media,
              playing: playing,
              muted: muted,
              onToggleMute: onToggleMute,
            )
          : Image.memory(
              media.photoBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
    );
  }
}

/// La vidéo d'une page : le lecteur natif scellé, en boucle, qui joue quand
/// la page est visible ; muette d'abord, un tap pour le son.
class _Video extends StatefulWidget {
  const _Video({
    required this.media,
    required this.playing,
    required this.muted,
    required this.onToggleMute,
  });

  final OpenedMedia media;
  final bool playing;
  final bool muted;
  final VoidCallback onToggleMute;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  late final SealedVideoController _controller = widget.media.videoController();
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Même écoute que la face d'une Vibe : un décodeur qui meurt doit se
    // voir, pas laisser une image noire avec du son.
    _controller.addListener(_onValeur);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          _controller.setLooping(true);
          _apply();
          setState(() {});
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  void _onValeur() {
    final e = _controller.value.error;
    if (e != null && _error == null && mounted) setState(() => _error = e);
  }

  void _apply() {
    if (!_controller.value.isInitialized) return;
    _controller.setVolume(widget.muted ? 0 : 1);
    widget.playing ? _controller.play() : _controller.pause();
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
    if (_error != null) return VideoFaceError(error: _error!);
    if (!_controller.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            color: Colors.white38,
            strokeWidth: 2,
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleMute,
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoWatchdog(
            controller: _controller,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _controller.value.size.width,
                height: _controller.value.size.height,
                child: SealedVideoView(_controller),
              ),
            ),
          ),
          Positioned(
            right: 10,
            bottom: 10,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.55),
              ),
              child: Icon(
                widget.muted ? Icons.volume_off : Icons.volume_up,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
