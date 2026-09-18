import 'package:flutter/material.dart';

import '../../../core/typography.dart';
import '../../../core/utils/ids.dart';
import '../../library/album_editor/album_draft.dart';
import '../../library/album_editor/editor_images.dart';
import '../../library/album_editor/editor_panels.dart';
import '../../library/album_editor/editor_theme.dart';
import '../../library/album_editor/grade_shader.dart';
import '../../library/album_editor/media_preview.dart';
import '../../library/album_editor/overlay_model.dart';
import '../../library/album_editor/sticker_picker.dart';
import 'vibe_edit_draft.dart';

/// **L'éditeur d'une Vibe** — le même que celui des Flows, adapté (Jay,
/// 2026-09-18 : *« l'actuel est vraiment trop basique […] inspire-toi de
/// celui qu'on a créé pour les Flows »*).
///
/// En haut, l'aperçu de la face courante dans son cadre 9:16
/// (`MediaPreview`) : cadrage au doigt, zoom à deux doigts, textes et
/// autocollants posés dessus, un texte tapé directement sur l'image. En
/// dessous, à la place de la bande des médias, la bascule **Recto / Verso**.
/// En bas, les outils des Flows **sans Format** — une Vibe est un 9:16,
/// point — et sans « + » ni « retirer » : les faces viennent de la prise.
///
/// L'écran ne calcule rien : il lit et modifie un [VibeEditDraft] (pur). Il
/// ne rend pas de fichier non plus : « Suivant » rend le brouillon, l'export
/// appartient à qui l'a ouvert (voir `VibeExport`) — c'est ce qui permet de
/// rouvrir l'éditeur depuis « À qui ? » avec les réglages encore là.
///
/// Rend le brouillon prêt, ou `null` si l'utilisateur abandonne la Vibe.
class VibeEditorScreen extends StatefulWidget {
  const VibeEditorScreen({
    super.key,
    required this.draft,
    this.startFront = true,
    this.firstPass = true,
  });

  final VibeEditDraft draft;

  /// La face ouverte d'abord (« Modifier » le verso depuis « À qui ? »).
  final bool startFront;

  /// Première ouverture, juste après la prise : fermer, c'est abandonner la
  /// Vibe. Rouvert depuis « À qui ? » : fermer ne perd que cette ouverture.
  final bool firstPass;

  @override
  State<VibeEditorScreen> createState() => _VibeEditorScreenState();
}

class _VibeEditorScreenState extends State<VibeEditorScreen> {
  late VibeEditDraft _draft = widget.draft;
  late var _front = widget.startFront || !widget.draft.hasBack;
  EditorTool? _tool;

  /// La face telle qu'elle était à l'ouverture du panneau : « Annuler » la rend.
  AlbumDraftMedia? _snapshot;
  String? _selectedOverlay;

  /// Le texte en cours d'écriture, tapé sur l'image ; nul sinon.
  TextOverlay? _editingText;
  final _textCtrl = TextEditingController();

  final _images = EditorImages();

  AlbumDraftMedia get _media => _draft.face(front: _front);

  @override
  void initState() {
    super.initState();
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
      setState(() => _draft = _draft.update(_front, f));

  // ── Les panneaux ────────────────────────────────────────────────────

  Future<void> _open(EditorTool tool) async {
    switch (tool) {
      case EditorTool.texte:
        _startText(null);
      case EditorTool.sticker:
        final s = await pickSticker(context);
        if (s != null && mounted) {
          if (!s.isEmoji) await _images.sticker(s.imagePath!);
          if (!mounted) return;
          _update((m) => m.withOverlay(s));
          setState(() => _selectedOverlay = s.id);
        }
      case EditorTool.filtre || EditorTool.modifier || EditorTool.rogner:
        setState(() {
          _snapshot = _media;
          _tool = tool;
          _selectedOverlay = null;
        });
      case EditorTool.cadrer:
        // Pas de Format sur une Vibe : la barre ne le propose pas.
        break;
    }
  }

  void _cancelPanel() {
    final snap = _snapshot;
    setState(() {
      if (snap != null) _draft = _draft.update(_front, (_) => snap);
      if (snap != null && snap.isVideo) _images.invalidate(snap);
      _snapshot = null;
      _tool = null;
    });
  }

  void _donePanel() => setState(() {
    if (_media.isVideo) _images.invalidate(_media);
    _snapshot = null;
    _tool = null;
  });

  // ── Les calques ─────────────────────────────────────────────────────

  void _onOverlayTapped(OverlayObject o) {
    if (o is TextOverlay) _startText(o);
  }

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
        _draft = _draft.update(_front, (m) => m.withoutOverlay(t.id));
        _selectedOverlay = null;
      } else {
        _draft = _draft.update(
          _front,
          (m) => m.withOverlay(t.copyWith(text: text)),
        );
      }
      _editingText = null;
    });
  }

  // ── Les faces ───────────────────────────────────────────────────────

  void _switchFace(bool front) {
    if (front == _front) return;
    setState(() {
      _front = front;
      _selectedOverlay = null;
    });
  }

  Future<void> _close() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          widget.firstPass
              ? 'Abandonner cette Vibe ?'
              : 'Annuler les modifications ?',
        ),
        content: Text(
          widget.firstPass
              ? 'La prise et les retouches seront perdues.'
              : 'Les retouches de cette ouverture seront perdues.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.firstPass ? 'Abandonner' : 'Annuler'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  void _next() => Navigator.of(context).pop(_draft);

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
                  EditorPrimaryButton(label: 'Suivant', onPressed: _next),
                ],
              ),
        body: Column(
          children: [
            Expanded(
              child: MediaPreview(
                // Une clé par face : changer de face reconstruit l'aperçu (et
                // son lecteur vidéo) au lieu de le recycler.
                key: ValueKey(media.id),
                media: media,
                aspect: VibeEditDraft.aspect.ratio,
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
              if (_draft.hasBack)
                _FaceSwitch(
                  front: _front,
                  frontEdited: _draft.frontEdited,
                  backEdited: _draft.backEdited,
                  onSelect: _switchFace,
                ),
              EditorToolbar(video: media.isVideo, format: false, onTool: _open),
            ] else
              EditorPanel(
                title: switch (tool) {
                  EditorTool.filtre => 'Filtre',
                  EditorTool.modifier => 'Modifier',
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
                  EditorTool.rogner => TrimPanel(
                    media: media,
                    maxMs: VibeEditDraft.maxVideoMs,
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

/// **Recto / Verso** — à la place de la bande des médias. Une pastille dit
/// quelle face porte déjà des retouches.
class _FaceSwitch extends StatelessWidget {
  const _FaceSwitch({
    required this.front,
    required this.frontEdited,
    required this.backEdited,
    required this.onSelect,
  });

  final bool front;
  final bool frontEdited;
  final bool backEdited;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = EditorColors.of(context);
    Widget chip(String label, bool isFront, bool edited) {
      final selected = front == isFront;
      return Expanded(
        child: Material(
          color: selected ? c.accent : c.raised,
          borderRadius: BorderRadius.circular(NeoRadius.md),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onSelect(isFront),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: NeoSpace.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: selected ? c.onAccent : c.ink,
                    ),
                  ),
                  if (edited) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? c.onAccent : c.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        NeoSpace.sm,
        NeoSpace.md,
        0,
      ),
      child: Row(
        children: [
          chip('Recto', true, frontEdited),
          const SizedBox(width: NeoSpace.sm),
          chip('Verso', false, backEdited),
        ],
      ),
    );
  }
}
