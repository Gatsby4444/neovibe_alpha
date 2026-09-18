import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/library_item.dart';
import '../../../core/typography.dart';
import '../album_editor/overlay_model.dart';
import '../library_repository.dart';
import 'caption_editor.dart';

/// **« Modifier la description »** (Jay, 2026-09-18) — une feuille depuis le
/// bas, avec le même éditeur qu'à la publication ([CaptionEditor]).
///
/// Rend la publication **mise à jour** quand la légende a été enregistrée,
/// `null` si l'utilisateur a refermé sans rien changer. Les écrans qui
/// tiennent une copie de la liste (le fil, le plein écran) remplacent alors
/// leur exemplaire — le dépôt, lui, a déjà invalidé la grille du profil.
Future<LibraryItem?> showEditCaptionSheet(
  BuildContext context,
  LibraryItem item,
) {
  return showModalBottomSheet<LibraryItem>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _EditCaptionSheet(item: item),
  );
}

class _EditCaptionSheet extends ConsumerStatefulWidget {
  const _EditCaptionSheet({required this.item});

  final LibraryItem item;

  @override
  ConsumerState<_EditCaptionSheet> createState() => _EditCaptionSheetState();
}

class _EditCaptionSheetState extends ConsumerState<_EditCaptionSheet> {
  late final _texte = TextEditingController(text: widget.item.caption ?? '');
  late OverlayFont? _police = overlayFontNamed(widget.item.captionFont);
  var _envoi = false;

  @override
  void dispose() {
    _texte.dispose();
    super.dispose();
  }

  Future<void> _enregistrer() async {
    setState(() => _envoi = true);
    final texte = _texte.text.trim();
    final caption = texte.isEmpty ? null : texte;
    final font = _police?.name;
    try {
      await ref
          .read(libraryRepositoryProvider)
          .updateCaption(widget.item.id, caption: caption, captionFont: font);
    } catch (e) {
      if (!mounted) return;
      setState(() => _envoi = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Impossible de modifier : $e')));
      return;
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(widget.item.withCaption(caption: caption, captionFont: font));
  }

  @override
  Widget build(BuildContext context) {
    // Le clavier pousse la feuille : la marge du bas suit sa hauteur.
    final clavier = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        NeoSpace.lg,
        0,
        NeoSpace.lg,
        clavier + NeoSpace.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Modifier la description',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: NeoSpace.sm),
          CaptionEditor(
            controller: _texte,
            font: _police,
            autofocus: true,
            onFontChanged: (f) => setState(() => _police = f),
          ),
          const SizedBox(height: NeoSpace.md),
          FilledButton(
            onPressed: _envoi ? null : _enregistrer,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: const StadiumBorder(),
            ),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}
