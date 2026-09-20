import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/location/anchor.dart';
import '../../../core/models/library_item.dart';
import '../../../core/typography.dart';
import '../../../core/utils/ids.dart';
import '../../cards/native_media.dart';
import 'album_caption_screen.dart';
import 'album_draft.dart';
import 'album_draft_keeper.dart';
import 'editor_images.dart';
import 'editor_panels.dart';
import 'editor_theme.dart';
import 'gallery/gallery_import.dart';
import 'gallery/gallery_screen.dart';
import 'grade_shader.dart';
import 'media_preview.dart';
import 'overlay_model.dart';
import 'publish_preparer.dart';
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
  const AlbumEditorScreen({
    super.key,
    required this.draft,
    required this.keeper,
    this.openCaption = false,
    this.anchor,
  });

  /// La position relevée au départ, quand elle arrive ; nulle pour un
  /// brouillon repris (il porte déjà la sienne).
  final Future<ContentAnchor?>? anchor;

  final AlbumDraft draft;

  /// Le gardien du brouillon : chaque retouche y est écrite, la publication
  /// l'efface (Brouillons, 2026-09-20).
  final AlbumDraftKeeper keeper;

  /// Reprise d'un brouillon laissé à la légende : on y va tout de suite.
  final bool openCaption;

  @override
  State<AlbumEditorScreen> createState() => _AlbumEditorScreenState();
}

class _AlbumEditorScreenState extends State<AlbumEditorScreen> {
  late AlbumDraft _draft = widget.draft;
  var _current = 0;
  EditorTool? _tool;

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

  /// Le dernier brouillon confié au gardien : tout autre est une retouche.
  AlbumDraft? _kept;

  AlbumDraftMedia get _media => _draft.media[_current];

  @override
  void initState() {
    super.initState();
    // Le shader est attendu ici : l'aperçu peint dès la première image.
    GradeShader.load().then((_) {
      if (mounted) setState(() {});
    });
    if (widget.openCaption) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _next();
      });
    }
    widget.anchor?.then((a) {
      if (a != null && mounted && _draft.anchor == null) {
        setState(() => _draft = _draft.copyWith(anchor: a));
      }
    });
  }

  /// Chaque brouillon différent du dernier confié part au gardien — appelé
  /// à la construction, donc après chaque `setState` qui l'a changé.
  void _keep() {
    if (identical(_draft, _kept)) return;
    _kept = _draft;
    widget.keeper.schedule(_draft, step: 'edit');
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

  Future<void> _open(EditorTool tool) async {
    switch (tool) {
      case EditorTool.texte:
        _startText(null);
      case EditorTool.sticker:
        final picked = await pickSticker(context);
        if (picked != null && mounted) {
          // L'image de l'autocollant rejoint le dossier du brouillon avant
          // d'être décodée (voir AlbumDraftKeeper).
          final s = picked.isEmoji
              ? picked
              : await widget.keeper.adoptSticker(picked);
          if (!mounted) return;
          if (!s.isEmoji) await _images.sticker(s.imagePath!);
          if (!mounted) return;
          _update((m) => m.withOverlay(s));
          setState(() => _selectedOverlay = s.id);
        }
      case EditorTool.filtre ||
          EditorTool.modifier ||
          EditorTool.rogner ||
          EditorTool.cadrer:
        setState(() {
          _snapshot = _media;
          _draftSnapshot = tool == EditorTool.cadrer ? _draft : null;
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
    final adopted = await widget.keeper.adoptMedia(more);
    if (!mounted) return;
    setState(() {
      _draft = _draft.add(adopted);
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
        title: const Text('Quitter cette publication ?'),
        // « Abandonner » garde le brouillon : c'est lui, la sécurité
        // (Jay, 2026-09-20).
        content: const Text(
          'Tu la retrouveras dans Réglages › Brouillons pendant 3 jours, '
          'telle que tu la laisses.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.keeper.flush();
    if (mounted) Navigator.of(context).pop();
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
    // **Le travail commence ici, pas à « Publier »** (Jay, 2026-09-19,
    // « comme les autres ») : pendant que l'utilisateur tape sa légende, le
    // service natif transcode, scelle et envoie déjà. « Publier » ne fait
    // que libérer ; revenir en arrière annule.
    final container = ProviderScope.containerOf(context, listen: false);
    // `ignore()` : l'erreur, s'il y en a une, est relue à l'`await` plus
    // bas — sans lui, elle serait aussi rapportée comme non gérée entre-temps.
    final preparing = container.read(publishPreparerProvider).start(_draft)
      ..ignore();
    final result = await Navigator.of(context).push<AlbumDraft>(
      MaterialPageRoute(
        builder: (_) => AlbumCaptionScreen(
          draft: _draft,
          coverThumb: _thumbFile(_draft.media.first),
          // La légende en train de s'écrire va au brouillon, comme une
          // retouche.
          onChanged: (d) => widget.keeper.schedule(d, step: 'caption'),
        ),
      ),
    );
    final PreparedPublication prepared;
    try {
      prepared = await preparing;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Préparation impossible : $e')));
      return;
    }
    if (result == null) {
      await prepared.cancel();
      // Retour à l'édition : le brouillon le dit.
      widget.keeper.schedule(_draft, step: 'edit');
      return;
    }
    await prepared.release(result);
    // Publiée : le brouillon n'a plus lieu d'être.
    await widget.keeper.delete();
    if (mounted) Navigator.of(context).pop(result);
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
    _keep();
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
              TextToolsPanel(
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
              EditorToolbar(
                video: media.isVideo,
                // Un Flow est en 9:16, point : pas de choix de format.
                format: !_draft.flow,
                onTool: _open,
              ),
            ] else
              EditorPanel(
                title: switch (tool) {
                  EditorTool.filtre => 'Filtre',
                  EditorTool.modifier => 'Modifier',
                  EditorTool.cadrer => 'Format',
                  EditorTool.rogner => 'Rogner',
                  _ => '',
                },
                onCancel: _cancelPanel,
                onDone: _donePanel,
                child: switch (tool) {
                  EditorTool.filtre => FilterPanel(
                    media: media,
                    images: _images,
                    onChanged: (f, strength) => _update(
                      (m) => m.copyWith(filter: f, filterStrength: strength),
                    ),
                  ),
                  EditorTool.modifier => AdjustPanel(
                    media: media,
                    onAdjust: (a) => _update((m) => m.copyWith(adjust: a)),
                    onCrop: (c) => _update((m) => m.copyWith(crop: c)),
                  ),
                  EditorTool.cadrer => _AspectPanel(
                    current: _draft.aspect,
                    onPick: (a) =>
                        setState(() => _draft = _draft.withAspect(a)),
                  ),
                  EditorTool.rogner => TrimPanel(
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
                          FileThumb(thumb: thumbOf(m)),
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
