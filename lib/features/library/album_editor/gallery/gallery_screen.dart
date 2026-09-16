import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/models/library_item.dart';
import '../../../../core/typography.dart';
import '../editor_theme.dart';
import 'gallery_feed.dart';
import 'gallery_import.dart';
import 'native_gallery.dart';

/// **« Nouvelle publication »** — la galerie du téléphone dans l'app, comme
/// Instagram : un grand aperçu du média en cours, et la grille des récents
/// dans un **panneau qu'on tire vers le haut** (jusqu'à 4/5 de l'écran —
/// retour de Jay : *« très désagréable de voir que 2 lignes à peine en bas »*).
/// Sélection **numérotée** (l'ordre de sélection est l'ordre de l'album),
/// l'appareil photo en première case.
///
/// Rend un [GalleryPick] : les [GalleryEntry] retenus dans l'ordre, ou un
/// fichier pris à l'appareil photo ; nul si l'utilisateur renonce. [max]
/// borne la sélection ; [single] pour un seul média (l'autocollant image).
///
/// L'écran ne parle pas au natif : [GalleryFeed] lui donne les pages et les
/// vignettes (les visibles d'abord), et ne sait rien de la sélection.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    required this.max,
    this.single = false,
    this.allowCamera = true,
  });

  final int max;
  final bool single;

  /// L'appareil photo en première case de la grille.
  final bool allowCamera;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _feed = GalleryFeed();
  final _selected = <GalleryEntry>[];
  GalleryEntry? _shown;
  var _permission = _Permission.pending;

  /// Le panneau de la grille : de la moitié à 4/5 de l'écran.
  static const _sheetMin = 0.42;
  static const _sheetInitial = 0.5;
  static const _sheetMax = 0.8;

  @override
  void initState() {
    super.initState();
    _feed.addListener(_onFeed);
    _askPermission();
  }

  @override
  void dispose() {
    _feed.removeListener(_onFeed);
    _feed.dispose();
    super.dispose();
  }

  Future<void> _askPermission() async {
    // Android 13+ : deux permissions, une par type ; avant : le stockage.
    final photos = await Permission.photos.request();
    final videos = await Permission.videos.request();
    final ok =
        photos.isGranted ||
        photos.isLimited ||
        videos.isGranted ||
        videos.isLimited;
    if (!mounted) return;
    setState(() => _permission = ok ? _Permission.granted : _Permission.denied);
    if (ok) await _feed.loadMore();
  }

  void _onFeed() {
    if (!mounted) return;
    setState(() {
      // Le premier média s'affiche en aperçu dès qu'il existe.
      _shown ??= _feed.entries.isEmpty ? null : _feed.entries.first;
    });
  }

  Future<void> _camera() async {
    final f = await GalleryImport.capture(context);
    if (f == null || !mounted) return;
    Navigator.of(context).pop(GalleryPick.file(f));
  }

  void _tap(GalleryEntry e) {
    setState(() {
      _shown = e;
      final i = _selected.indexOf(e);
      if (i >= 0) {
        _selected.removeAt(i);
        return;
      }
      if (widget.single) {
        _selected
          ..clear()
          ..add(e);
        return;
      }
      if (_selected.length >= widget.max) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${widget.max} média${widget.max > 1 ? 's' : ''} au plus par publication.',
            ),
          ),
        );
        return;
      }
      _selected.add(e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Fermer',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.single ? 'Choisir une image' : 'Nouvelle publication',
        ),
        actions: [
          EditorPrimaryButton(
            label: 'Suivant',
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.of(
                    context,
                  ).pop(GalleryPick.entries(List.of(_selected))),
          ),
        ],
      ),
      body: switch (_permission) {
        _Permission.pending => const Center(child: CircularProgressIndicator()),
        _Permission.denied => _Denied(onRetry: _askPermission),
        _Permission.granted => Stack(
          children: [
            // L'aperçu, derrière le panneau : au ratio de la publication,
            // et il reste visible au-dessus du panneau replié.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: AspectRatio(
                aspectRatio: AlbumAspect.portrait.ratio,
                child: _Preview(feed: _feed, entry: _shown, canvas: c.canvas),
              ),
            ),
            // La grille, dans un panneau qu'on tire.
            DraggableScrollableSheet(
              initialChildSize: _sheetInitial,
              minChildSize: _sheetMin,
              maxChildSize: _sheetMax,
              snap: true,
              snapSizes: const [_sheetMin, _sheetMax],
              builder: (context, scroll) => DecoratedBox(
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(NeoRadius.lg),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(NeoRadius.lg),
                  ),
                  child: CustomScrollView(
                    controller: scroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: _SheetHeader(
                          count: _selected.length,
                          max: widget.max,
                          single: widget.single,
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.only(bottom: NeoSpace.xl),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 2,
                                crossAxisSpacing: 2,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              if (widget.allowCamera) {
                                if (i == 0) {
                                  return _CameraTile(onTap: _camera);
                                }
                                i -= 1;
                              }
                              // Une page de plus quand on approche de la fin.
                              if (i >= _feed.entries.length - 16) {
                                _feed.loadMore();
                              }
                              final e = _feed.entries[i];
                              final rank = _selected.indexOf(e);
                              return _Tile(
                                feed: _feed,
                                entry: e,
                                rank: rank < 0 ? null : rank + 1,
                                shown: e == _shown,
                                single: widget.single,
                                accent: c.accent,
                                onTap: () => _tap(e),
                              );
                            },
                            childCount:
                                _feed.entries.length +
                                (widget.allowCamera ? 1 : 0),
                          ),
                        ),
                      ),
                      if (_feed.isLoading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(NeoSpace.lg),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      },
    );
  }
}

enum _Permission { pending, granted, denied }

/// Ce que l'écran rend : des médias de la galerie, ou un fichier pris à
/// l'appareil photo.
class GalleryPick {
  const GalleryPick.entries(this.entries) : file = null;
  const GalleryPick.file(this.file) : entries = const [];
  final List<GalleryEntry> entries;
  final File? file;
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.count,
    required this.max,
    required this.single,
  });

  final int count;
  final int max;
  final bool single;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Column(
      children: [
        const SizedBox(height: NeoSpace.sm),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: c.inkFaint,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NeoSpace.lg,
            NeoSpace.sm,
            NeoSpace.lg,
            NeoSpace.sm,
          ),
          child: Row(
            children: [
              Text(
                'Récents',
                style: TextStyle(
                  fontFamily: NeoType.display,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: c.ink,
                ),
              ),
              const Spacer(),
              if (!single)
                Text(
                  count == 0 ? 'jusqu\'à $max' : '$count / $max',
                  style: TextStyle(
                    fontSize: 13,
                    color: count == 0 ? c.inkFaint : c.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Denied extends StatelessWidget {
  const _Denied({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NeoSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 40, color: c.inkFaint),
            const SizedBox(height: NeoSpace.md),
            Text(
              'NeoVibe a besoin d\'accéder à tes photos et vidéos pour les '
              'publier. Rien n\'est envoyé sans ton geste.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.inkMuted),
            ),
            const SizedBox(height: NeoSpace.lg),
            FilledButton(
              onPressed: () async {
                await openAppSettings();
                await onRetry();
              },
              child: const Text('Ouvrir les réglages'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le grand aperçu : une vignette large (le système la rend vite, déjà
/// orientée), en « couvrir » dans le cadre.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.feed,
    required this.entry,
    required this.canvas,
  });
  final GalleryFeed feed;
  final GalleryEntry? entry;
  final Color canvas;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    if (e == null) return ColoredBox(color: canvas);
    return ColoredBox(
      color: canvas,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Thumb(
            feed: feed,
            entry: e,
            size: 720,
            priority: true,
            key: ValueKey('big${e.uri}'),
          ),
          if (e.isVideo)
            Positioned(
              right: NeoSpace.md,
              bottom: NeoSpace.md,
              child: _DurationBadge(ms: e.durationMs ?? 0, large: true),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.feed,
    required this.entry,
    required this.rank,
    required this.shown,
    required this.single,
    required this.accent,
    required this.onTap,
  });

  final GalleryFeed feed;
  final GalleryEntry entry;
  final int? rank;
  final bool shown;
  final bool single;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = rank != null;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Thumb(feed: feed, entry: entry, size: 256),
          if (selected) ColoredBox(color: Colors.white.withValues(alpha: 0.28)),
          if (shown && !selected)
            ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
          if (entry.isVideo)
            Positioned(
              right: 4,
              bottom: 4,
              child: _DurationBadge(ms: entry.durationMs ?? 0),
            ),
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? accent : Colors.black.withValues(alpha: 0.25),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: selected
                  ? single
                        ? const Icon(Icons.check, size: 14, color: Colors.white)
                        : Text(
                            '$rank',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Une vignette, depuis le cache du flux — sans clignotement quand la grille
/// se reconstruit : le cache synchrone répond avant toute attente.
///
/// Trois états DISTINCTS : en attente (gris), arrivée (l'image), refusée par
/// le système (une icône) — un échec qui ressemble à une attente, c'est ce qui
/// a rendu le premier jet illisible (« beaucoup sont noires »).
class _Thumb extends StatefulWidget {
  const _Thumb({
    super.key,
    required this.feed,
    required this.entry,
    required this.size,
    this.priority = false,
  });

  final GalleryFeed feed;
  final GalleryEntry entry;
  final int size;
  final bool priority;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(covariant _Thumb old) {
    super.didUpdateWidget(old);
    if (old.entry.uri != widget.entry.uri || old.size != widget.size) {
      _bytes = null;
      _failed = false;
      _ask();
    }
  }

  void _ask() {
    final cached = widget.feed.cachedThumbnail(widget.entry.uri, widget.size);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    final uri = widget.entry.uri;
    widget.feed
        .thumbnail(uri, size: widget.size, priority: widget.priority)
        .then(
          (b) {
            if (mounted && widget.entry.uri == uri) setState(() => _bytes = b);
          },
          onError: (_) {
            if (mounted && widget.entry.uri == uri) {
              setState(() => _failed = true);
            }
          },
        );
  }

  @override
  void dispose() {
    // Une case qui a défilé hors de l'écran n'a plus besoin de sa vignette :
    // elle rend sa place aux cases visibles.
    widget.feed.forget(widget.entry.uri, size: widget.size);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: widget.size,
        errorBuilder: (_, _, _) => ColoredBox(
          color: c.raised,
          child: Icon(Icons.broken_image_outlined, color: c.inkFaint),
        ),
      );
    }
    if (_failed) {
      return ColoredBox(
        color: c.raised,
        child: Icon(
          widget.entry.isVideo
              ? Icons.videocam_off_outlined
              : Icons.broken_image_outlined,
          color: c.inkFaint,
        ),
      );
    }
    return ColoredBox(color: c.raised);
  }
}

class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: c.raised,
        child: Icon(Icons.photo_camera_outlined, color: c.ink),
      ),
    );
  }
}

class _DurationBadge extends StatelessWidget {
  const _DurationBadge({required this.ms, this.large = false});
  final int ms;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final s = (ms / 1000).round();
    final text =
        '${(s ~/ 60).toString().padLeft(large ? 2 : 1, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 8 : 5,
        vertical: large ? 3 : 1,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(large ? 8 : 4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam, size: large ? 14 : 10, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: large ? 12 : 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
