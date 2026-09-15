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
/// Instagram : un grand aperçu du média en cours, la grille des récents, une
/// sélection **numérotée** (l'ordre de sélection est l'ordre de l'album),
/// l'appareil photo en première case.
///
/// Rend un [GalleryPick] : les [GalleryEntry] retenus dans l'ordre, ou un
/// fichier pris à l'appareil photo ; nul si l'utilisateur renonce. [max]
/// borne la sélection ; [single] pour un seul média (l'autocollant image).
///
/// L'écran ne parle pas au natif : [GalleryFeed] lui donne les pages et les
/// vignettes, et ne sait rien de la sélection.
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
  final _scroll = ScrollController();
  final _selected = <GalleryEntry>[];
  GalleryEntry? _shown;
  var _permission = _Permission.pending;

  @override
  void initState() {
    super.initState();
    _feed.addListener(_onFeed);
    _scroll.addListener(_onScroll);
    _askPermission();
  }

  @override
  void dispose() {
    _feed.removeListener(_onFeed);
    _feed.dispose();
    _scroll.dispose();
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

  void _onScroll() {
    if (_scroll.position.extentAfter < 600) _feed.loadMore();
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
    final accent = EditorColors.accent(context);
    return Theme(
      data: editorTheme(context),
      child: Scaffold(
        appBar: AppBar(
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
          _Permission.pending => const Center(
            child: CircularProgressIndicator(color: EditorColors.inkMuted),
          ),
          _Permission.denied => _Denied(onRetry: _askPermission),
          _Permission.granted => Column(
            children: [
              // L'aperçu, au ratio de la publication.
              AspectRatio(
                aspectRatio: AlbumAspect.tall.ratio,
                child: _Preview(feed: _feed, entry: _shown),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NeoSpace.lg,
                  NeoSpace.sm,
                  NeoSpace.lg,
                  NeoSpace.xs,
                ),
                child: Row(
                  children: [
                    const Text(
                      'Récents',
                      style: TextStyle(
                        fontFamily: NeoType.display,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: EditorColors.ink,
                      ),
                    ),
                    const Spacer(),
                    if (!widget.single)
                      Text(
                        _selected.isEmpty
                            ? 'jusqu\'à ${widget.max}'
                            : '${_selected.length} / ${widget.max}',
                        style: TextStyle(
                          fontSize: 13,
                          color: _selected.isEmpty
                              ? EditorColors.inkFaint
                              : accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: NeoSpace.xl),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount:
                      _feed.entries.length + (widget.allowCamera ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (widget.allowCamera) {
                      if (i == 0) return _CameraTile(onTap: _camera);
                      i -= 1;
                    }
                    final e = _feed.entries[i];
                    final rank = _selected.indexOf(e);
                    return _Tile(
                      feed: _feed,
                      entry: e,
                      rank: rank < 0 ? null : rank + 1,
                      shown: e == _shown,
                      single: widget.single,
                      accent: accent,
                      onTap: () => _tap(e),
                    );
                  },
                ),
              ),
            ],
          ),
        },
      ),
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

class _Denied extends StatelessWidget {
  const _Denied({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NeoSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              size: 40,
              color: EditorColors.inkFaint,
            ),
            const SizedBox(height: NeoSpace.md),
            const Text(
              'NeoVibe a besoin d\'accéder à tes photos et vidéos pour les '
              'publier. Rien n\'est envoyé sans ton geste.',
              textAlign: TextAlign.center,
              style: TextStyle(color: EditorColors.inkMuted),
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
  const _Preview({required this.feed, required this.entry});
  final GalleryFeed feed;
  final GalleryEntry? entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    if (e == null) return const ColoredBox(color: EditorColors.surface);
    return ColoredBox(
      color: EditorColors.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Thumb(
            feed: feed,
            entry: e,
            size: 1080,
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
          _Thumb(feed: feed, entry: entry, size: 300),
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
/// se reconstruit : le cache synchrone répond avant le `FutureBuilder`.
class _Thumb extends StatelessWidget {
  const _Thumb({
    super.key,
    required this.feed,
    required this.entry,
    required this.size,
  });

  final GalleryFeed feed;
  final GalleryEntry entry;
  final int size;

  @override
  Widget build(BuildContext context) {
    final cached = feed.cachedThumbnail(entry.uri, size);
    if (cached != null) return _image(cached);
    return FutureBuilder<Uint8List>(
      future: feed.thumbnail(entry.uri, size: size),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return const ColoredBox(color: EditorColors.raised);
        }
        return _image(bytes);
      },
    );
  }

  Widget _image(Uint8List bytes) => Image.memory(
    bytes,
    fit: BoxFit.cover,
    gaplessPlayback: true,
    cacheWidth: size,
    errorBuilder: (_, _, _) => const ColoredBox(
      color: EditorColors.raised,
      child: Icon(Icons.broken_image_outlined, color: EditorColors.inkFaint),
    ),
  );
}

class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const ColoredBox(
        color: EditorColors.raised,
        child: Icon(Icons.photo_camera_outlined, color: EditorColors.ink),
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
