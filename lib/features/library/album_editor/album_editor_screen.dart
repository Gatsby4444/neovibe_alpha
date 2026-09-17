import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/models/library_item.dart';
import '../../../core/typography.dart';
import '../../../core/utils/ids.dart';
import '../../cards/native_media.dart';
import 'album_caption_screen.dart';
import 'album_draft.dart';
import 'color_grade.dart';
import 'editor_images.dart';
import 'editor_theme.dart';
import 'gallery/gallery_import.dart';
import 'gallery/gallery_screen.dart';
import 'grade_shader.dart';
import 'media_preview.dart';
import 'overlay_model.dart';
import 'sticker_picker.dart';

/// **L'éditeur d'album** — « digne d'Instagram », sans les musiques (Jay,
/// 2026-09-15), dans le thème de l'app (clair, sable ou sombre : la DA prime,
/// retour de Jay du même jour).
///
/// En haut, l'aperçu du média courant et son cadre 3:4 (`MediaPreview`) : on
/// le cadre au doigt, on le zoome à deux doigts ; les textes et autocollants
/// se posent dessus, et **un texte se tape directement sur l'image**. En
/// dessous, la bande des médias (appui long pour réordonner, « + » pour en
/// ajouter). En bas, **cinq outils** façon Instagram : Texte · Superposition ·
/// Filtre · Modifier · Rogner (vidéo). Un outil ouvert devient un panneau avec
/// **Annuler / Terminé** : Annuler rend le média tel qu'il était à
/// l'ouverture du panneau.
///
/// L'écran ne calcule rien : il lit et modifie un [AlbumDraft] (pur). Le
/// shader de l'aperçu et le peintre des calques sont ceux de l'export.
///
/// Rend le brouillon prêt à publier, ou `null` si l'utilisateur renonce.
class AlbumEditorScreen extends StatefulWidget {
  const AlbumEditorScreen({super.key, required this.draft});

  final AlbumDraft draft;

  @override
  State<AlbumEditorScreen> createState() => _AlbumEditorScreenState();
}

enum _Tool { texte, sticker, filtre, modifier, cadrer, rogner }

class _AlbumEditorScreenState extends State<AlbumEditorScreen> {
  late AlbumDraft _draft = widget.draft;
  var _current = 0;
  _Tool? _tool;

  /// Le média tel qu'il était à l'ouverture du panneau : « Annuler » le rend.
  AlbumDraftMedia? _snapshot;

  /// Le brouillon ENTIER, pour un panneau qui touche à toute la publication
  /// (le format : il remet les cadrages de tous les médias). L'instantané
  /// d'un seul média ne saurait pas les rendre.
  AlbumDraft? _draftSnapshot;
  String? _selectedOverlay;

  /// Le texte en cours d'écriture, tapé sur l'image ; nul sinon.
  TextOverlay? _editingText;
  final _textCtrl = TextEditingController();

  final _images = EditorImages();

  AlbumDraftMedia get _media => _draft.media[_current];

  @override
  void initState() {
    super.initState();
    // Le shader est attendu ici : l'aperçu peint dès la première image.
    GradeShader.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _images.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  void _update(AlbumDraftMedia Function(AlbumDraftMedia) f) =>
      setState(() => _draft = _draft.update(_media.id, f));

  // ── Les panneaux ────────────────────────────────────────────────────

  Future<void> _open(_Tool tool) async {
    switch (tool) {
      case _Tool.texte:
        _startText(null);
      case _Tool.sticker:
        final s = await pickSticker(context);
        if (s != null && mounted) {
          if (!s.isEmoji) await _images.sticker(s.imagePath!);
          if (!mounted) return;
          _update((m) => m.withOverlay(s));
          setState(() => _selectedOverlay = s.id);
        }
      case _Tool.filtre || _Tool.modifier || _Tool.rogner || _Tool.cadrer:
        setState(() {
          _snapshot = _media;
          _draftSnapshot = tool == _Tool.cadrer ? _draft : null;
          _tool = tool;
          _selectedOverlay = null;
        });
    }
  }

  void _cancelPanel() {
    final snap = _snapshot;
    final draftSnap = _draftSnapshot;
    setState(() {
      if (draftSnap != null) {
        _draft = draftSnap;
      } else if (snap != null) {
        _draft = _draft.update(snap.id, (_) => snap);
      }
      if (snap != null && snap.isVideo) _images.invalidate(snap);
      _snapshot = null;
      _draftSnapshot = null;
      _tool = null;
    });
  }

  void _donePanel() => setState(() {
    if (_media.isVideo) _images.invalidate(_media);
    _snapshot = null;
    _draftSnapshot = null;
    _tool = null;
  });

  // ── Les calques ─────────────────────────────────────────────────────

  void _onOverlayTapped(OverlayObject o) {
    if (o is TextOverlay) _startText(o);
  }

  /// Écrire un texte, nouveau ou existant, **sur l'image** : le champ est
  /// dans l'aperçu, le clavier s'ouvre, la barre du bas devient les outils de
  /// texte (police · couleur · alignement · fond).
  void _startText(TextOverlay? existing) {
    final t = existing ?? TextOverlay(id: newUuid(), text: '');
    _textCtrl.text = t.text;
    _textCtrl.selection = TextSelection.collapsed(offset: t.text.length);
    setState(() {
      _editingText = t;
      _selectedOverlay = t.id;
      _tool = null;
    });
  }

  void _doneText() {
    final t = _editingText;
    if (t == null) return;
    final text = _textCtrl.text.trim();
    setState(() {
      if (text.isEmpty) {
        // Texte vidé : le calque s'en va (ou ne naît pas).
        _draft = _draft.update(_media.id, (m) => m.withoutOverlay(t.id));
        _selectedOverlay = null;
      } else {
        _draft = _draft.update(
          _media.id,
          (m) => m.withOverlay(t.copyWith(text: text)),
        );
      }
      _editingText = null;
    });
  }

  // ── La bande ────────────────────────────────────────────────────────

  Future<void> _add() async {
    final pick = await Navigator.of(context).push<GalleryPick>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => GalleryScreen(max: _draft.freeSlots),
      ),
    );
    if (pick == null || !mounted) return;
    final more = pick.file != null
        ? await GalleryImport.fromFiles(context, [
            pick.file!,
          ], freeSlots: _draft.freeSlots)
        : await GalleryImport.toDraftMedia(
            context,
            pick.entries,
            freeSlots: _draft.freeSlots,
          );
    if (more.isEmpty || !mounted) return;
    setState(() {
      _draft = _draft.add(more);
      _current = _draft.media.length - 1;
    });
  }

  void _remove() {
    if (_draft.media.length == 1) {
      _close();
      return;
    }
    setState(() {
      _draft = _draft.remove(_media.id);
      _current = _current.clamp(0, _draft.media.length - 1);
      _selectedOverlay = null;
    });
  }

  Future<void> _close() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandonner cette publication ?'),
        content: const Text('Les retouches seront perdues.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _next() async {
    // Une vidéo seule publiée par la voie « publication » devient un Flow :
    // on le DIT avant, et on propose l'éditeur Flow (9:16, plein écran).
    // Ignorer est permis — le Flow garde alors son format d'origine, avec
    // des bandes noires en plein écran, comme Instagram (Jay, 2026-09-18).
    if (!_draft.flow && _draft.videoSeule) {
      final choix = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Ta vidéo deviendra un Flow'),
          content: const Text(
            'Une vidéo publiée seule est un Flow : elle se lira en plein '
            'écran, comme un Reel.\n\n'
            'Passer à l\'éditeur Flow la cadre en 9:16 pour prendre tout '
            'l\'écran. Continuer la garde telle quelle — avec des bandes '
            'noires autour, en plein écran.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'continuer'),
              child: const Text('Continuer'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'flow'),
              child: const Text('Éditeur Flow'),
            ),
          ],
        ),
      );
      if (!mounted || choix == null) return;
      if (choix == 'flow') {
        // Sur place : le même média, le format 9:16, les cadrages remis.
        setState(() {
          _draft = _draft.enFlow();
          _current = 0;
          _tool = null;
          _selectedOverlay = null;
        });
        _images.invalidate(_media);
        return;
      }
    }
    final result = await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        builder: (_) => AlbumCaptionScreen(
          draft: _draft,
          coverThumb: _thumbFile(_draft.media.first),
        ),
      ),
    );
    if (result != null && mounted) Navigator.of(context).pop(result);
  }

  final _thumbFiles = <String, Future<File?>>{};

  /// La vignette-fichier d'un média (la source pour une photo, une image
  /// extraite pour une vidéo) — la bande et l'écran de légende.
  Future<File?> _thumbFile(AlbumDraftMedia m) {
    if (!m.isVideo) return Future.value(m.source);
    return _thumbFiles.putIfAbsent(m.id, () async {
      final temp = await getTemporaryDirectory();
      final dest = File('${temp.path}/album_thumb_${m.id}.jpg');
      final ok = await NativeMedia.videoThumbnail(
        source: m.source.path,
        dest: dest.path,
        width: 320,
        atMs: m.effectiveTrim.startMs,
      );
      return ok ? dest : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = _media;
    final tool = _tool;
    final editing = _editingText;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_editingText != null) {
          _doneText();
        } else if (_tool != null) {
          _cancelPanel();
        } else {
          _close();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: editing != null
            // En écriture : rien d'autre que « Terminé ».
            ? AppBar(
                automaticallyImplyLeading: false,
                actions: [
                  EditorPrimaryButton(label: 'Terminé', onPressed: _doneText),
                ],
              )
            : AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Abandonner',
                  onPressed: _close,
                ),
                title: const Text('Modifier'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Retirer ce média',
                    onPressed: _remove,
                  ),
                  EditorPrimaryButton(label: 'Suivant', onPressed: _next),
                ],
              ),
        body: Column(
          children: [
            Expanded(
              child: MediaPreview(
                // Une clé par média : changer de média reconstruit
                // l'aperçu (et son lecteur vidéo) au lieu de le recycler.
                key: ValueKey(media.id),
                media: media,
                aspect: _draft.aspect.ratio,
                images: _images,
                selectedOverlayId: _selectedOverlay,
                editingText: editing,
                textController: _textCtrl,
                interactive: editing == null,
                onCrop: (c) => _update((m) => m.copyWith(crop: c)),
                onOverlayChanged: (o) => _update((m) => m.withOverlay(o)),
                onOverlaySelected: (id) =>
                    setState(() => _selectedOverlay = id),
                onOverlayTapped: _onOverlayTapped,
                onOverlayRemoved: (id) {
                  _update((m) => m.withoutOverlay(id));
                  setState(() => _selectedOverlay = null);
                },
              ),
            ),
            if (editing != null)
              _TextToolsPanel(
                overlay: editing,
                onChanged: (t) => setState(() => _editingText = t),
              )
            else if (tool == null) ...[
              _Strip(
                draft: _draft,
                current: _current,
                thumbOf: _thumbFile,
                onSelect: (i) => setState(() {
                  _current = i;
                  _selectedOverlay = null;
                }),
                onReorder: (from, to) => setState(() {
                  final id = _media.id;
                  _draft = _draft.reorder(from, to);
                  _current = _draft.media.indexWhere((m) => m.id == id);
                }),
                onAdd: _draft.isFull ? null : _add,
              ),
              _Toolbar(
                video: media.isVideo,
                // Un Flow est en 9:16, point : pas de choix de format.
                format: !_draft.flow,
                onTool: _open,
              ),
            ] else
              _Panel(
                title: switch (tool) {
                  _Tool.filtre => 'Filtre',
                  _Tool.modifier => 'Modifier',
                  _Tool.cadrer => 'Format',
                  _Tool.rogner => 'Rogner',
                  _ => '',
                },
                onCancel: _cancelPanel,
                onDone: _donePanel,
                child: switch (tool) {
                  _Tool.filtre => _FilterPanel(
                    media: media,
                    images: _images,
                    onChanged: (f, strength) => _update(
                      (m) => m.copyWith(filter: f, filterStrength: strength),
                    ),
                  ),
                  _Tool.modifier => _AdjustPanel(
                    media: media,
                    onAdjust: (a) => _update((m) => m.copyWith(adjust: a)),
                    onCrop: (c) => _update((m) => m.copyWith(crop: c)),
                  ),
                  _Tool.cadrer => _AspectPanel(
                    current: _draft.aspect,
                    onPick: (a) =>
                        setState(() => _draft = _draft.withAspect(a)),
                  ),
                  _Tool.rogner => _TrimPanel(
                    media: media,
                    maxMs: _draft.maxVideoMs,
                    onTrim: (t) => _update((m) => m.copyWith(trim: t)),
                  ),
                  _ => const SizedBox.shrink(),
                },
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Les outils de texte, pendant l'écriture sur l'image
// ---------------------------------------------------------------------------

enum _TextRow { fonts, colors }

/// Police · couleur · alignement · fond — la rangée des polices ou des
/// couleurs au-dessus, comme sur Instagram. Ce que l'utilisateur change ici
/// se voit tout de suite dans le champ posé sur l'image.
class _TextToolsPanel extends StatefulWidget {
  const _TextToolsPanel({required this.overlay, required this.onChanged});

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;

  @override
  State<_TextToolsPanel> createState() => _TextToolsPanelState();
}

class _TextToolsPanelState extends State<_TextToolsPanel> {
  var _row = _TextRow.fonts;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final o = widget.overlay;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: switch (_row) {
              _TextRow.fonts => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: NeoSpace.md,
                  vertical: NeoSpace.sm,
                ),
                children: [
                  for (final f in OverlayFont.values)
                    Padding(
                      padding: const EdgeInsets.only(right: NeoSpace.sm),
                      child: ChoiceChip(
                        label: Text(
                          f.label,
                          style: TextStyle(
                            fontFamily: f.family,
                            fontWeight: FontWeight
                                .values[(f.weight ~/ 100 - 1).clamp(0, 8)],
                          ),
                        ),
                        selected: f == o.font,
                        showCheckmark: false,
                        onSelected: (_) =>
                            widget.onChanged(o.copyWith(font: f)),
                      ),
                    ),
                ],
              ),
              _TextRow.colors => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: NeoSpace.md,
                  vertical: NeoSpace.sm,
                ),
                children: [
                  for (final col in OverlayColors.swatches)
                    GestureDetector(
                      onTap: () => widget.onChanged(o.copyWith(color: col)),
                      child: Container(
                        width: 36,
                        height: 36,
                        margin: const EdgeInsets.only(right: NeoSpace.sm),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: col,
                          border: Border.all(
                            color: col == o.color ? c.accent : c.line,
                            width: col == o.color ? 3 : 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.md,
              NeoSpace.xs,
              NeoSpace.md,
              NeoSpace.md,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _TextToolButton(
                  icon: Icons.text_fields,
                  active: _row == _TextRow.fonts,
                  tooltip: 'Police',
                  onTap: () => setState(() => _row = _TextRow.fonts),
                ),
                _TextToolButton(
                  icon: Icons.palette_outlined,
                  active: _row == _TextRow.colors,
                  tooltip: 'Couleur',
                  onTap: () => setState(() => _row = _TextRow.colors),
                ),
                _TextToolButton(
                  icon: switch (o.alignment) {
                    TextAlignment.left => Icons.format_align_left,
                    TextAlignment.center => Icons.format_align_center,
                    TextAlignment.right => Icons.format_align_right,
                  },
                  tooltip: 'Alignement',
                  onTap: () => widget.onChanged(
                    o.copyWith(
                      alignment:
                          TextAlignment.values[(o.alignment.index + 1) %
                              TextAlignment.values.length],
                    ),
                  ),
                ),
                _TextToolButton(
                  icon: switch (o.backdrop) {
                    TextBackdrop.none => Icons.font_download_outlined,
                    TextBackdrop.solid => Icons.font_download,
                    TextBackdrop.translucent =>
                      Icons.font_download_off_outlined,
                  },
                  active: o.backdrop != TextBackdrop.none,
                  tooltip: 'Fond',
                  onTap: () => widget.onChanged(
                    o.copyWith(
                      backdrop:
                          TextBackdrop.values[(o.backdrop.index + 1) %
                              TextBackdrop.values.length],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TextToolButton extends StatelessWidget {
  const _TextToolButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NeoSpace.sm),
      child: Material(
        color: active ? c.accent : c.raised,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Tooltip(
            message: tooltip,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, color: active ? c.onAccent : c.ink),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// La bande des médias
// ---------------------------------------------------------------------------

class _Strip extends StatelessWidget {
  const _Strip({
    required this.draft,
    required this.current,
    required this.thumbOf,
    required this.onSelect,
    required this.onReorder,
    required this.onAdd,
  });

  final AlbumDraft draft;
  final int current;
  final Future<File?> Function(AlbumDraftMedia) thumbOf;
  final ValueChanged<int> onSelect;
  final void Function(int from, int to) onReorder;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final accent = c.accent;
    return SizedBox(
      height: 76,
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: NeoSpace.md,
                vertical: NeoSpace.sm,
              ),
              buildDefaultDragHandles: false,
              proxyDecorator: (child, _, _) => Material(
                color: Colors.transparent,
                child: Opacity(opacity: 0.85, child: child),
              ),
              itemCount: draft.media.length,
              onReorderItem: onReorder,
              itemBuilder: (context, i) {
                final m = draft.media[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(m.id),
                  index: i,
                  child: GestureDetector(
                    onTap: () => onSelect(i),
                    child: Container(
                      width: 60,
                      margin: const EdgeInsets.only(right: NeoSpace.sm),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(NeoRadius.sm),
                        border: Border.all(
                          color: i == current ? accent : c.line,
                          width: i == current ? 2 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _FileThumb(thumb: thumbOf(m)),
                          if (m.isVideo)
                            const Positioned(
                              right: 3,
                              bottom: 3,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          if (m.overlays.isNotEmpty)
                            const Positioned(
                              left: 3,
                              bottom: 3,
                              child: Icon(
                                Icons.layers_outlined,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (onAdd != null)
            Padding(
              padding: const EdgeInsets.only(right: NeoSpace.md),
              child: IconButton.outlined(
                icon: Icon(Icons.add),
                tooltip:
                    'Ajouter (${draft.freeSlots} place'
                    '${draft.freeSlots > 1 ? 's' : ''})',
                style: IconButton.styleFrom(
                  foregroundColor: c.ink,
                  side: BorderSide(color: c.line),
                ),
                onPressed: onAdd,
              ),
            ),
        ],
      ),
    );
  }
}

class _FileThumb extends StatelessWidget {
  const _FileThumb({required this.thumb});
  final Future<File?> thumb;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return FutureBuilder<File?>(
      future: thumb,
      builder: (context, snap) {
        final file = snap.data;
        if (file == null) return ColoredBox(color: c.raised);
        return Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: 200,
          gaplessPlayback: true,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// La barre d'outils, et le panneau
// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.video,
    required this.onTool,
    this.format = true,
  });

  final bool video;

  /// L'outil Format (le ratio de la publication). Absent pour un Flow.
  final bool format;
  final ValueChanged<_Tool> onTool;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final tools = [
      (_Tool.texte, Icons.text_fields, 'Texte'),
      (_Tool.sticker, Icons.emoji_emotions_outlined, 'Superposition'),
      (_Tool.filtre, Icons.auto_awesome_outlined, 'Filtre'),
      (_Tool.modifier, Icons.tune, 'Modifier'),
      if (format) (_Tool.cadrer, Icons.crop, 'Format'),
      if (video) (_Tool.rogner, Icons.content_cut, 'Rogner'),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NeoSpace.md,
          NeoSpace.sm,
          NeoSpace.md,
          NeoSpace.md,
        ),
        child: Row(
          children: [
            for (var i = 0; i < tools.length; i++) ...[
              if (i > 0) const SizedBox(width: NeoSpace.sm),
              Expanded(
                child: Material(
                  color: c.raised,
                  borderRadius: BorderRadius.circular(NeoRadius.md),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onTool(tools[i].$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: NeoSpace.sm,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(tools[i].$2, size: 22, color: c.ink),
                          const SizedBox(height: 4),
                          Text(
                            tools[i].$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: c.ink),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Un panneau d'outil : son contenu, puis **Annuler · Titre · Terminé** en
/// bas, comme sur Instagram.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.onCancel,
    required this.onDone,
    required this.child,
  });

  final String title;
  final VoidCallback onCancel;
  final VoidCallback onDone;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 168, child: child),
          Row(
            children: [
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
                ),
                child: const Text('Annuler'),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: NeoType.display,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: c.ink,
                  ),
                ),
              ),
              TextButton(
                onPressed: onDone,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
                ),
                child: const Text(
                  'Terminé',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: NeoSpace.xs),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Format — les trois ratios d'une publication
// ---------------------------------------------------------------------------

/// Les trois formats d'Instagram, repris tels quels (Jay, 2026-09-17) :
/// **4:5** (le portrait, celui qui prend le plus d'écran), **1:1** et
/// **1,91:1**. Le choix vaut pour la publication ENTIÈRE — c'est le sens du
/// format chez eux : *« le ratio du premier média s'applique automatiquement
/// à tous les suivants »*.
class _AspectPanel extends StatelessWidget {
  const _AspectPanel({required this.current, required this.onPick});

  final AlbumAspect current;
  final ValueChanged<AlbumAspect> onPick;

  static const _choix = [
    (AlbumAspect.portrait, 'Portrait', '4:5'),
    (AlbumAspect.square, 'Carré', '1:1'),
    (AlbumAspect.landscape, 'Paysage', '1,91:1'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final (aspect, nom, label) in _choix)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
              child: GestureDetector(
                onTap: () => onPick(aspect),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // La vignette a la FORME du format : on choisit une
                    // forme, pas un mot.
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: aspect.ratio,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: aspect == current ? c.ink : c.inkFaint,
                                width: aspect == current ? 2.5 : 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: NeoSpace.xs),
                    Text(
                      nom,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: aspect == current
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: aspect == current ? c.ink : c.inkMuted,
                      ),
                    ),
                    Text(
                      label,
                      style: TextStyle(fontSize: 11, color: c.inkMuted),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filtre — les puces, et l'intensité au second tap
// ---------------------------------------------------------------------------

class _FilterPanel extends StatefulWidget {
  const _FilterPanel({
    required this.media,
    required this.images,
    required this.onChanged,
  });

  final AlbumDraftMedia media;
  final EditorImages images;
  final void Function(AlbumFilter filter, double strength) onChanged;

  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  ui.Image? _small;
  var _tuning = false;

  @override
  void initState() {
    super.initState();
    widget.images.small(widget.media).then((img) {
      if (mounted) setState(() => _small = img);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final accent = c.accent;
    final m = widget.media;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: _tuning && m.filter != AlbumFilter.normal
              ? Row(
                  children: [
                    const SizedBox(width: NeoSpace.lg),
                    Expanded(
                      child: Slider(
                        value: m.filterStrength,
                        onChanged: (v) => widget.onChanged(m.filter, v),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${(m.filterStrength * 100).round()}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.inkMuted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: NeoSpace.sm),
                  ],
                )
              : Center(
                  child: Text(
                    m.filter == AlbumFilter.normal
                        ? 'Choisis un filtre'
                        : 'Appuie à nouveau pour ajuster',
                    style: TextStyle(color: c.inkFaint, fontSize: 12),
                  ),
                ),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
            itemCount: AlbumFilter.values.length,
            itemBuilder: (context, i) {
              final f = AlbumFilter.values[i];
              final selected = f == m.filter;
              return GestureDetector(
                onTap: () {
                  if (selected) {
                    setState(() => _tuning = !_tuning);
                  } else {
                    setState(() => _tuning = false);
                    widget.onChanged(f, 1);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.only(right: NeoSpace.md),
                  child: Column(
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(NeoRadius.sm),
                          border: Border.all(
                            color: selected ? accent : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        // Chaque puce montre CE média à travers CE filtre, par
                        // le même shader que l'aperçu et que l'export.
                        child: _small == null
                            ? ColoredBox(color: c.raised)
                            : CustomPaint(
                                painter: GradedThumbPainter(
                                  image: _small!,
                                  media: m,
                                  aspect: 1,
                                  grade: f.grade,
                                ),
                              ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        f.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected ? accent : c.inkMuted,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Modifier — les réglages en ronds, un curseur pour celui qu'on touche
// ---------------------------------------------------------------------------

enum _Knob {
  straighten('Redresser', Icons.crop_rotate, -45, 45),
  lux('Lux', Icons.auto_fix_high, 0, 1),
  brightness('Luminosité', Icons.wb_sunny_outlined, -1, 1),
  contrast('Contraste', Icons.contrast, -1, 1),
  warmth('Chaleur', Icons.thermostat, -1, 1),
  saturation('Saturation', Icons.water_drop_outlined, -1, 1),
  tint('Teinte', Icons.color_lens_outlined, -1, 1),
  highlights('Hautes lumières', Icons.light_mode_outlined, -1, 1),
  shadows('Ombres', Icons.dark_mode_outlined, -1, 1),
  fade('Fondu', Icons.cloud_outlined, 0, 1),
  vignette('Vignette', Icons.vignette_outlined, 0, 1),
  sharpen('Netteté', Icons.change_history, 0, 1);

  const _Knob(this.label, this.icon, this.min, this.max);
  final String label;
  final IconData icon;
  final double min;
  final double max;

  double of(AlbumDraftMedia m) => switch (this) {
    straighten => m.crop.angle,
    lux => m.adjust.lux,
    brightness => m.adjust.brightness,
    contrast => m.adjust.contrast,
    warmth => m.adjust.warmth,
    saturation => m.adjust.saturation,
    tint => m.adjust.tint,
    highlights => m.adjust.highlights,
    shadows => m.adjust.shadows,
    fade => m.adjust.fade,
    vignette => m.adjust.vignette,
    sharpen => m.adjust.sharpen,
  };

  ColorGrade set(ColorGrade g, double v) => switch (this) {
    straighten => g,
    lux => g.copyWith(lux: v),
    brightness => g.copyWith(brightness: v),
    contrast => g.copyWith(contrast: v),
    warmth => g.copyWith(warmth: v),
    saturation => g.copyWith(saturation: v),
    tint => g.copyWith(tint: v),
    highlights => g.copyWith(highlights: v),
    shadows => g.copyWith(shadows: v),
    fade => g.copyWith(fade: v),
    vignette => g.copyWith(vignette: v),
    sharpen => g.copyWith(sharpen: v),
  };

  /// Ce que le curseur affiche : des degrés, ou un pourcentage.
  String display(double v) =>
      this == straighten ? '${v.round()}°' : '${(v * 100).round()}';
}

class _AdjustPanel extends StatefulWidget {
  const _AdjustPanel({
    required this.media,
    required this.onAdjust,
    required this.onCrop,
  });

  final AlbumDraftMedia media;
  final ValueChanged<ColorGrade> onAdjust;
  final ValueChanged<CropSpec> onCrop;

  @override
  State<_AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends State<_AdjustPanel> {
  _Knob? _knob;

  void _set(_Knob k, double v) {
    if (k == _Knob.straighten) {
      widget.onCrop(widget.media.crop.copyWith(angle: v));
    } else {
      widget.onAdjust(k.set(widget.media.adjust, v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final accent = c.accent;
    final m = widget.media;
    final k = _knob;
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: k == null
              ? Center(
                  child: Text(
                    'Touche un réglage',
                    style: TextStyle(color: c.inkFaint, fontSize: 12),
                  ),
                )
              : Row(
                  children: [
                    const SizedBox(width: NeoSpace.md),
                    if (k == _Knob.straighten)
                      IconButton(
                        icon: Icon(Icons.rotate_90_degrees_cw_outlined),
                        tooltip: 'Tourner d\'un quart de tour',
                        onPressed: () => widget.onCrop(m.crop.turned()),
                      ),
                    Expanded(
                      child: Slider(
                        value: k.of(m).clamp(k.min, k.max),
                        min: k.min,
                        max: k.max,
                        onChanged: (v) => _set(k, v),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        k.display(k.of(m)),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.inkMuted, fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.restart_alt, size: 20),
                      tooltip: 'Remettre à zéro',
                      onPressed: k.of(m) == 0 ? null : () => _set(k, 0),
                    ),
                  ],
                ),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NeoSpace.md),
            itemCount: _Knob.values.length,
            itemBuilder: (context, i) {
              final knob = _Knob.values[i];
              final active = knob == k;
              final touched = knob.of(m) != 0;
              return GestureDetector(
                onTap: () => setState(() => _knob = knob),
                child: Padding(
                  padding: const EdgeInsets.only(right: NeoSpace.lg),
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? Colors.white : Colors.transparent,
                          border: Border.all(
                            color: active ? Colors.white : c.inkMuted,
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          knob.icon,
                          size: 26,
                          color: active ? Colors.black : c.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        knob.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: active ? c.ink : c.inkMuted,
                        ),
                      ),
                      // Un point sous les réglages touchés, pour les retrouver.
                      Container(
                        width: 5,
                        height: 5,
                        margin: const EdgeInsets.only(top: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: touched ? accent : Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rogner — début, fin, couverture (vidéo)
// ---------------------------------------------------------------------------

class _TrimPanel extends StatefulWidget {
  const _TrimPanel({
    required this.media,
    required this.onTrim,
    this.maxMs = kAlbumMaxVideoMs,
  });

  final AlbumDraftMedia media;
  final ValueChanged<VideoTrim> onTrim;

  /// Une minute pour une publication, trois pour un Flow.
  final int maxMs;

  @override
  State<_TrimPanel> createState() => _TrimPanelState();
}

class _TrimPanelState extends State<_TrimPanel> {
  Timer? _debounce;
  Future<File?>? _cover;

  static String _mmss(int ms) {
    final s = (ms / 1000).round();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  void _refreshCover(VideoTrim t) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final temp = await getTemporaryDirectory();
      final dest = File(
        '${temp.path}/album_cover_${widget.media.id}_${t.coverMs}.jpg',
      );
      final ok = await NativeMedia.videoThumbnail(
        source: widget.media.source.path,
        dest: dest.path,
        width: 240,
        atMs: t.coverMs,
      );
      if (mounted) setState(() => _cover = Future.value(ok ? dest : null));
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshCover(widget.media.effectiveTrim);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    final m = widget.media;
    final duration = m.durationMs!.toDouble();
    final t = m.effectiveTrim;
    final label = TextStyle(color: c.inkMuted, fontSize: 12);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            const SizedBox(width: NeoSpace.md),
            Text(_mmss(t.startMs), style: label),
            Expanded(
              child: RangeSlider(
                values: RangeValues(t.startMs.toDouble(), t.endMs.toDouble()),
                min: 0,
                max: duration,
                onChanged: (v) {
                  var s = v.start.round();
                  var e = v.end.round();
                  // Au plus la limite du format : la borne qu'on n'a pas
                  // touchée suit.
                  if (e - s > widget.maxMs) {
                    if (s != t.startMs) {
                      e = s + widget.maxMs;
                    } else {
                      s = e - widget.maxMs;
                    }
                  }
                  widget.onTrim(
                    t
                        .copyWith(startMs: s, endMs: e)
                        .normalized(m.durationMs!, maxMs: widget.maxMs),
                  );
                },
              ),
            ),
            Text(_mmss(t.endMs), style: label),
            const SizedBox(width: NeoSpace.md),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: NeoSpace.md),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NeoRadius.sm),
                border: Border.all(color: c.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: _cover == null
                  ? const SizedBox.shrink()
                  : _FileThumb(thumb: _cover!),
            ),
            const SizedBox(width: NeoSpace.sm),
            Text('Couverture', style: label),
            Expanded(
              child: Slider(
                value: t.coverMs.toDouble().clamp(
                  t.startMs.toDouble(),
                  (t.endMs - 1).toDouble(),
                ),
                min: t.startMs.toDouble(),
                max: (t.endMs - 1).toDouble(),
                onChanged: (v) {
                  final n = t.copyWith(coverMs: v.round());
                  widget.onTrim(n);
                  _refreshCover(n);
                },
              ),
            ),
            Text('${((t.endMs - t.startMs) / 1000).round()} s', style: label),
            const SizedBox(width: NeoSpace.md),
          ],
        ),
      ],
    );
  }
}
