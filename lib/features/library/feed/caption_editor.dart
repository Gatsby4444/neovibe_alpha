import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../album_editor/overlay_model.dart';
import 'publication_caption.dart';

/// **La saisie d'une légende et le choix de sa police** — le même widget à
/// la publication (`AlbumCaptionScreen`) et à la modification après coup
/// (`EditCaptionSheet`, Jay 2026-09-18 : *« Modifier la description »*).
///
/// Un seul endroit sait ce qu'est une légende qu'on tape : sa limite
/// ([kCaptionMax], la même qu'en base), sa capitalisation, ses polices. Deux
/// copies auraient divergé au premier réglage — et l'une des deux aurait
/// menti sur ce que la base accepte.
class CaptionEditor extends StatelessWidget {
  const CaptionEditor({
    super.key,
    required this.controller,
    required this.font,
    required this.onFontChanged,
    this.leading,
    this.autofocus = false,
  });

  final TextEditingController controller;

  /// La police choisie ; nulle = celle du texte courant.
  final OverlayFont? font;
  final ValueChanged<OverlayFont?> onFontChanged;

  /// Ce qui se pose à gauche du champ : la couverture, à la publication.
  final Widget? leading;

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: NeoSpace.md),
            ],
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: autofocus,
                maxLines: 6,
                minLines: 3,
                maxLength: kCaptionMax,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Écris une légende…',
                  border: InputBorder.none,
                  filled: false,
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        // Les polices : chacune écrit son propre nom, c'est le seul aperçu
        // qui dise vraiment ce qu'on choisit.
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in OverlayFont.values)
                Padding(
                  padding: const EdgeInsets.only(right: NeoSpace.sm),
                  child: GestureDetector(
                    onTap: () => onFontChanged(f),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: NeoSpace.md,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: font == f
                              ? context.palette.ink
                              : context.palette.ink.withValues(alpha: 0.2),
                          width: font == f ? 2 : 1,
                        ),
                      ),
                      child: Text(
                        f.label,
                        style: TextStyle(
                          fontFamily: f.family,
                          fontWeight: FontWeight.values[(f.weight ~/ 100) - 1],
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// La police d'une légende, retrouvée par son nom — nulle si le nom ne
/// correspond plus à rien.
OverlayFont? overlayFontNamed(String? name) {
  if (name == null) return null;
  for (final f in OverlayFont.values) {
    if (f.name == name) return f;
  }
  return null;
}
