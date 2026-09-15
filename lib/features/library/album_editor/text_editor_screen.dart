import 'package:flutter/material.dart';

import '../../../core/typography.dart';
import '../../../core/utils/ids.dart';
import 'editor_theme.dart';
import 'overlay_model.dart';

/// **Écrire un texte sur le média** — comme sur Instagram : le texte se tape
/// en grand, au centre, avec en bas la rangée des polices ou des couleurs, et
/// quatre boutons : police · couleur · alignement · fond.
///
/// Rend le [TextOverlay] (nouveau ou modifié), ou nul si l'utilisateur
/// renonce ou vide le texte.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, this.initial});

  final TextOverlay? initial;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

enum _Row { fonts, colors }

class _TextEditorScreenState extends State<TextEditorScreen> {
  late final _controller = TextEditingController(text: widget.initial?.text);
  late var _draft = widget.initial ?? TextOverlay(id: newUuid(), text: '');
  var _row = _Row.fonts;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() {
    final text = _controller.text.trim();
    Navigator.of(
      context,
    ).pop(text.isEmpty ? null : _draft.copyWith(text: text));
  }

  TextStyle _style(double fontSize) => TextStyle(
    fontFamily: _draft.font.family,
    fontFamilyFallback: const ['Figtree', 'Roboto', 'sans-serif'],
    fontWeight: FontWeight.values[(_draft.font.weight ~/ 100 - 1).clamp(0, 8)],
    fontSize: fontSize,
    height: 1.15,
    color: _draft.color,
    shadows: _draft.font.effect == 'neon'
        ? [
            Shadow(color: _draft.color, blurRadius: fontSize * 0.35),
            Shadow(color: _draft.color, blurRadius: fontSize * 0.7),
          ]
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final accent = EditorColors.accent(context);
    final dark = _draft.color.computeLuminance() > 0.5;
    final backdrop = switch (_draft.backdrop) {
      TextBackdrop.none => null,
      TextBackdrop.solid => (dark ? Colors.black : Colors.white),
      TextBackdrop.translucent =>
        (dark ? Colors.black : Colors.white).withValues(alpha: 0.45),
    };
    return Theme(
      data: editorTheme(context),
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.82),
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _done,
                  child: const Text(
                    'Terminé',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NeoSpace.xl,
                    ),
                    child: Container(
                      padding: backdrop == null
                          ? EdgeInsets.zero
                          : const EdgeInsets.symmetric(
                              horizontal: NeoSpace.md,
                              vertical: NeoSpace.xs,
                            ),
                      decoration: backdrop == null
                          ? null
                          : BoxDecoration(
                              color: backdrop,
                              borderRadius: BorderRadius.circular(NeoRadius.sm),
                            ),
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        maxLines: null,
                        textAlign: switch (_draft.alignment) {
                          TextAlignment.left => TextAlign.left,
                          TextAlignment.center => TextAlign.center,
                          TextAlignment.right => TextAlign.right,
                        },
                        textCapitalization: TextCapitalization.sentences,
                        cursorColor: _draft.color,
                        style: _style(30),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Écris…',
                          hintStyle: _style(30).copyWith(
                            color: _draft.color.withValues(alpha: 0.4),
                          ),
                          isCollapsed: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // La rangée active : polices, ou couleurs.
              SizedBox(
                height: 56,
                child: switch (_row) {
                  _Row.fonts => ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NeoSpace.md,
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
                            selected: f == _draft.font,
                            selectedColor: Colors.white,
                            labelStyle: TextStyle(
                              color: f == _draft.font
                                  ? Colors.black
                                  : Colors.white,
                            ),
                            backgroundColor: EditorColors.raised,
                            side: BorderSide.none,
                            showCheckmark: false,
                            onSelected: (_) => setState(
                              () => _draft = _draft.copyWith(font: f),
                            ),
                          ),
                        ),
                    ],
                  ),
                  _Row.colors => ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NeoSpace.md,
                      vertical: NeoSpace.sm,
                    ),
                    children: [
                      for (final c in OverlayColors.swatches)
                        GestureDetector(
                          onTap: () => setState(
                            () => _draft = _draft.copyWith(color: c),
                          ),
                          child: Container(
                            width: 36,
                            height: 36,
                            margin: const EdgeInsets.only(right: NeoSpace.sm),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c,
                              border: Border.all(
                                color: c == _draft.color
                                    ? accent
                                    : Colors.white,
                                width: c == _draft.color ? 3 : 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                },
              ),
              // Les quatre boutons.
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
                    _ToolButton(
                      icon: Icons.text_fields,
                      active: _row == _Row.fonts,
                      tooltip: 'Police',
                      onTap: () => setState(() => _row = _Row.fonts),
                    ),
                    _ToolButton(
                      icon: Icons.palette_outlined,
                      active: _row == _Row.colors,
                      tooltip: 'Couleur',
                      onTap: () => setState(() => _row = _Row.colors),
                    ),
                    _ToolButton(
                      icon: switch (_draft.alignment) {
                        TextAlignment.left => Icons.format_align_left,
                        TextAlignment.center => Icons.format_align_center,
                        TextAlignment.right => Icons.format_align_right,
                      },
                      tooltip: 'Alignement',
                      onTap: () => setState(
                        () => _draft = _draft.copyWith(
                          alignment:
                              TextAlignment.values[(_draft.alignment.index +
                                      1) %
                                  TextAlignment.values.length],
                        ),
                      ),
                    ),
                    _ToolButton(
                      icon: switch (_draft.backdrop) {
                        TextBackdrop.none => Icons.font_download_outlined,
                        TextBackdrop.solid => Icons.font_download,
                        TextBackdrop.translucent =>
                          Icons.font_download_off_outlined,
                      },
                      active: _draft.backdrop != TextBackdrop.none,
                      tooltip: 'Fond',
                      onTap: () => setState(
                        () => _draft = _draft.copyWith(
                          backdrop:
                              TextBackdrop.values[(_draft.backdrop.index + 1) %
                                  TextBackdrop.values.length],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NeoSpace.sm),
      child: Material(
        color: active ? Colors.white : EditorColors.raised,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Tooltip(
            message: tooltip,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, color: active ? Colors.black : Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
