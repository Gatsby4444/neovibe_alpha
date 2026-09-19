import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_preloader.dart';
import '../../../core/crypto/media_open.dart';
import '../../../core/models/library_item.dart';
import '../../../core/video/sealed_video_controller.dart';
import '../../../core/video/sealed_video_view.dart';
import '../../../core/video/video_watchdog.dart';
import '../../../core/widgets/vibe_face.dart';

/// **Le carrousel d'un album** : ses médias à son ratio, feuilletés à
/// l'horizontale, une vidéo qui joue quand la page est visible
/// et que la cellule est active — muette d'abord, un tap pour le son (comme
/// dans un fil). Même composant dans le fil du profil et, demain, dans le
/// feed. Les **points** ne sont plus dessus : la cellule les pose SOUS le
/// média, comme Instagram (Jay, 2026-09-19 — il y en avait deux).
class AlbumCarousel extends ConsumerStatefulWidget {
  const AlbumCarousel({
    super.key,
    required this.item,
    required this.active,
    this.onPageChanged,
    this.onTap,
    this.initialPage = 0,
  });

  final LibraryItem item;

  /// La cellule est celle qu'on regarde : ses vidéos peuvent jouer.
  final bool active;
  final ValueChanged<int>? onPageChanged;

  /// Un tap sur le média (pas sur le bouton du son) : ouvrir en grand — un
  /// Flow, en plein écran (Jay, 2026-09-19). Nul = le tap ne fait rien.
  final VoidCallback? onTap;
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

  /// **Les pages dont le lecteur a existé** (2026-09-20, Jay : *« je voulais
  /// l'image sur laquelle je me suis arrêté »*). Un lecteur déjà créé n'est
  /// plus détruit quand on quitte sa page : il est **suspendu** (le décodeur
  /// est rendu, la texture garde sa dernière image, la position reste —
  /// vérifié dans `Player.stop()` de media3 : *does not clear the playlist,
  /// reset the playback position*). Revenir dessus = l'image exacte où on
  /// s'était arrêté, puis ça repart de là.
  ///
  /// ⚠️ Borné aux **voisines** (± 1) de la page courante : une texture
  /// suspendue coûte quelques Mo de mémoire graphique (pas de décodeur). Au-delà,
  /// la page redevient une couverture et son lecteur est détruit — mais sa
  /// **position** est gardée ([_positions]), et le lecteur recréé repart de là.
  final _visited = <int>{};

  /// La position (ms) où chaque vidéo en était quand son lecteur a été
  /// détruit — un nombre par page, ça ne coûte rien et vaut pour toutes.
  final _positions = <int, int>{};

  /// Les pages déjà rouvertes après un fichier local disparu : une fois.
  final _recovered = <int>{};

  /// Le fichier de MON média n'est plus sur l'appareil (le cache l'a balayé
  /// sous le lecteur — 2026-09-20). L'ouverture, mise en cache par le
  /// fournisseur, pointe encore dessus : on l'invalide, et la page se
  /// rouvre depuis le serveur, comme pour le média de quelqu'un d'autre.
  void _lost(int i, ContentFace spec) {
    if (!_recovered.add(i)) return;
    ref.invalidate(contentFaceProvider(spec));
  }

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
    // Une photo : ses octets. Une vidéo : l'URL signée, la clé ET ses premiers
    // blocs (`preload` amorce le cache par le natif) — sans quoi la page
    // suivante montrait une roue le temps de ces allers-retours (Jay,
    // 2026-09-20).
    if (_current + 1 < media.length) {
      final next = media[_current + 1];
      if (next.isVideo) {
        ref.read(contentPreloaderProvider).preload(_spec(next));
      } else {
        ref.watch(contentFaceProvider(_spec(next)));
      }
    }
    // Le format dans le fil, sans jamais de bandes noires (Jay, 2026-09-19) :
    // - un **Flow** s'affiche **à son format** — 9:16 pour un vrai Flow
    //   (porte « Un Flow »), le format de sa publication (1:1, 4:5, 1,91:1)
    //   pour une vidéo seule requalifiée ; c'est le plein écran qui force le
    //   9:16, avec des bandes pour compléter (`contain`) ;
    // - un **album** ne monte pas plus haut que 4:5.
    final ratio = (item.aspect ?? AlbumAspect.portrait).ratio;
    return AspectRatio(
      aspectRatio: item.isFlow ? ratio : math.max(ratio, kVibeFeedRatio),
      // Le tap enveloppe le carrousel : le bouton du son, DANS une page, est
      // plus profond, et c'est le plus profond qui gagne un tap.
      //
      // ⚠️ La zone neutre : un carrousel d'UNE page (un Flow, une photo seule)
      // n'a rien à feuilleter, et Flutter ne lui donne alors AUCUN geste
      // horizontal — le balayage remontait à la couverture du fil, qui se
      // fermait (Jay, 2026-09-19). Le geste est absorbé ici, sans effet ; sur
      // plusieurs pages, le `PageView`, plus profond, le garde comme avant.
      child: GestureDetector(
        onTap: widget.onTap,
        onHorizontalDragStart: (_) {},
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            PageView.builder(
              controller: _pages,
              itemCount: media.length,
              // Les pages voisines restent CONSTRUITES (une de chaque côté) :
              // c'est ce qui permet à un lecteur suspendu d'y survivre. Sans
              // ceci, le PageView détruit la page dès qu'elle sort de l'écran.
              allowImplicitScrolling: true,
              onPageChanged: (i) {
                setState(() => _current = i);
                widget.onPageChanged?.call(i);
              },
              itemBuilder: (context, i) => _Page(
                spec: _spec(media[i]),
                // La couverture d'une vidéo : ce qu'on montre quand son
                // lecteur n'existe pas, et jusqu'à sa première image.
                poster: _posterSpec(media[i]),
                isVideo: media[i].isVideo,
                playing: widget.active && i == _current,
                keepPlayer: _visited.contains(i) && (i - _current).abs() <= 1,
                initialPositionMs: _positions[i] ?? 0,
                onPlayerCreated: () => _visited.add(i),
                onPlayerLeft: (ms) => _positions[i] = ms,
                onLost: () => _lost(i, _spec(media[i])),
                muted: _muted,
                onToggleMute: () => setState(() => _muted = !_muted),
              ),
            ),
            if (media.length > 1)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
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
          ],
        ),
      ),
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
///
/// **Depuis le 2026-09-20**, un lecteur qui a existé **survit** sur les pages
/// voisines ([keepPlayer]) : suspendu, sans décodeur, sa texture gardant la
/// dernière image. Et la couverture reste affichée par-dessus la vidéo
/// jusqu'à sa première image — plus de flash noir.
class _Page extends ConsumerWidget {
  const _Page({
    required this.spec,
    required this.poster,
    required this.isVideo,
    required this.playing,
    required this.keepPlayer,
    required this.initialPositionMs,
    required this.onPlayerCreated,
    required this.onPlayerLeft,
    required this.onLost,
    required this.muted,
    required this.onToggleMute,
  });

  final ContentFace spec;

  /// La couverture, si c'est une vidéo qui en a une.
  final ContentFace? poster;
  final bool isVideo;
  final bool playing;

  /// Le lecteur de cette page, s'il existe, reste en vie (suspendu).
  final bool keepPlayer;

  /// Où reprendre si le lecteur est recréé (ms).
  final int initialPositionMs;
  final VoidCallback onPlayerCreated;
  final ValueChanged<int> onPlayerLeft;

  /// Le fichier local du média a disparu : à rouvrir.
  final VoidCallback onLost;
  final bool muted;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Une vidéo qu'on ne regarde pas, sans lecteur à garder : sa couverture,
    // et rien d'autre.
    if (isVideo && !playing && !keepPlayer && poster != null) {
      return _Poster(spec: poster!, withPlayIcon: true);
    }
    final opened = ref.watch(contentFaceProvider(spec));
    return opened.when(
      // Le temps d'ouvrir : la couverture (si vidéo) plutôt qu'un fond noir.
      loading: () => _Poster(spec: poster, withSpinner: true),
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
              poster: poster,
              playing: playing,
              initialPositionMs: initialPositionMs,
              onCreated: onPlayerCreated,
              onLeft: onPlayerLeft,
              onLost: onLost,
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

/// La couverture d'une vidéo : une image, qui tient lieu de vidéo tant que
/// celle-ci n'a pas d'image à montrer. Sans couverture : un fond noir.
class _Poster extends ConsumerWidget {
  const _Poster({
    required this.spec,
    this.withPlayIcon = false,
    this.withSpinner = false,
  });

  final ContentFace? spec;
  final bool withPlayIcon;
  final bool withSpinner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = spec == null
        ? null
        : ref.watch(contentFaceProvider(spec!)).asData?.value.photoBytes;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image != null)
          Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true)
        else
          const ColoredBox(color: Colors.black),
        if (withPlayIcon)
          const Center(
            child: Icon(
              Icons.play_circle_outline,
              color: Colors.white70,
              size: 46,
            ),
          ),
        if (withSpinner)
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                color: Colors.white38,
                strokeWidth: 2,
              ),
            ),
          ),
      ],
    );
  }
}

/// La vidéo d'une page : le lecteur natif scellé, en boucle, qui joue quand
/// la page est visible ; muette d'abord, un tap pour le son.
class _Video extends StatefulWidget {
  const _Video({
    required this.media,
    required this.poster,
    required this.playing,
    required this.initialPositionMs,
    required this.onCreated,
    required this.onLeft,
    required this.onLost,
    required this.muted,
    required this.onToggleMute,
  });

  final OpenedMedia media;
  final ContentFace? poster;
  final bool playing;
  final int initialPositionMs;
  final VoidCallback onCreated;
  final ValueChanged<int> onLeft;
  final VoidCallback onLost;
  final bool muted;
  final VoidCallback onToggleMute;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  late final SealedVideoController _controller = widget.media.videoController();
  Object? _error;
  var _hasFirstFrame = false;

  @override
  void initState() {
    super.initState();
    widget.onCreated();
    // Même écoute que la face d'une Vibe : un décodeur qui meurt doit se
    // voir, pas laisser une image noire avec du son.
    _controller.addListener(_onValeur);
    _controller
        .initialize()
        .then((_) async {
          if (!mounted) return;
          _controller.setLooping(true);
          // Reprendre où on en était, si ce lecteur en remplace un autre.
          if (widget.initialPositionMs > 0) {
            await _controller.seekTo(
              Duration(milliseconds: widget.initialPositionMs),
            );
          }
          if (!mounted) return;
          _apply();
          setState(() {});
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() => _error = e);
          _siPerdu(e);
        });
  }

  /// Un média LOCAL qui échoue : le fichier a très probablement disparu
  /// (« média introuvable », ou « Source error » sous un lecteur suspendu).
  /// La page le rouvrira depuis le serveur. Un média en flux qui échoue,
  /// lui, ne cache rien : l'erreur reste affichée.
  void _siPerdu(Object e) {
    if (widget.media.sealedVideo == null && widget.media.clearFile == null) {
      return;
    }
    widget.onLost();
  }

  void _onValeur() {
    final v = _controller.value;
    if (v.error != null && _error == null && mounted) {
      setState(() => _error = v.error);
      _siPerdu(v.error!);
    }
    // La couverture se retire à la PREMIÈRE image rendue — c'est le signal
    // du natif, pas « le lecteur est prêt » : entre les deux, la texture est
    // noire, et c'était le flash de Jay (2026-09-20).
    if (v.hasFirstFrame && !_hasFirstFrame && mounted) {
      setState(() => _hasFirstFrame = true);
    }
  }

  /// Regardée : le lecteur joue. Pas regardée : il **rend son décodeur**
  /// (`suspend`, 2026-09-19) et garde sa dernière image à l'écran — le fil
  /// construit ses cellules 800 px d'avance, et chacune tenait un décodeur
  /// matériel : 4 à 6 en vie, saccades.
  void _apply() {
    if (!_controller.value.isInitialized) return;
    _controller.setVolume(widget.muted ? 0 : 1);
    widget.playing ? _controller.resume(play: true) : _controller.suspend();
  }

  @override
  void didUpdateWidget(covariant _Video old) {
    super.didUpdateWidget(old);
    _apply();
  }

  @override
  void dispose() {
    // Où on en était : le lecteur recréé repartira de là.
    widget.onLeft(_controller.value.position.inMilliseconds);
    _controller.removeListener(_onValeur);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return VideoFaceError(error: _error!);
    if (!_controller.value.isInitialized) {
      return _Poster(spec: widget.poster, withSpinner: true);
    }
    // ⚠️ Le son ne bascule QUE sur son bouton (Jay, 2026-09-19) : avant, un
    // tap n'importe où sur la vidéo le coupait ou l'allumait — et le tap
    // d'un Flow doit ouvrir le plein écran.
    return Stack(
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
        // La couverture PAR-DESSUS la texture jusqu'à la première image.
        if (!_hasFirstFrame) _Poster(spec: widget.poster),
        Positioned(
          right: 10,
          bottom: 10,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggleMute,
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
        ),
      ],
    );
  }
}
