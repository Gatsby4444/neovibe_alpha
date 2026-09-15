import 'package:flutter/material.dart';

import '../../../core/typography.dart';
import '../../../core/utils/ids.dart';
import 'gallery/gallery_import.dart';
import 'gallery/gallery_screen.dart';
import 'overlay_model.dart';

/// **Superposition** : un autocollant à poser sur le média — un émoji, ou
/// une image de la galerie. Rend le [StickerOverlay], ou nul.
Future<StickerOverlay?> pickSticker(BuildContext context) async {
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _StickerSheet(),
  );
  if (choice == null || !context.mounted) return null;
  if (choice is String) {
    return StickerOverlay(id: newUuid(), emoji: choice);
  }
  // Une image de la galerie : notre écran, en sélection simple.
  final pick = await Navigator.of(context).push<GalleryPick>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          const GalleryScreen(max: 1, single: true, allowCamera: false),
    ),
  );
  if (pick == null || pick.entries.isEmpty) return null;
  final file = await GalleryImport.copy(pick.entries.first);
  return StickerOverlay(id: newUuid(), imagePath: file.path);
}

class _StickerSheet extends StatelessWidget {
  const _StickerSheet();

  /// Une sélection tenue à la main : ce que les gens posent vraiment sur une
  /// photo. Le clavier émoji du téléphone reste la voie pour tout le reste.
  static const _emojis = [
    '😀',
    '😂',
    '🥹',
    '😍',
    '😎',
    '🤩',
    '🥳',
    '😭',
    '😤',
    '🤯',
    '🫠',
    '😴',
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🤍',
    '💔',
    '💯',
    '🔥',
    '✨',
    '⭐',
    '🌟',
    '💫',
    '⚡',
    '🌈',
    '☀️',
    '🌙',
    '🌊',
    '🍕',
    '🍔',
    '🍟',
    '🍺',
    '🍷',
    '☕',
    '🎉',
    '🎊',
    '🎶',
    '🎤',
    '🎧',
    '📸',
    '🎬',
    '🏆',
    '🥇',
    '⚽',
    '🏀',
    '🎮',
    '🚀',
    '✈️',
    '🚗',
    '🏖️',
    '🏔️',
    '🎡',
    '👀',
    '👋',
    '🙌',
    '👏',
    '🤝',
    '💪',
    '🫶',
    '🤞',
    '✌️',
    '👍',
    '👎',
    '🙏',
    '💀',
    '👻',
    '🤖',
    '🐶',
    '🐱',
    '🦊',
    '🐻',
    '🦁',
    '🐸',
    '🦋',
    '🌸',
    '🌹',
    '🌻',
    '🍀',
    '🎈',
    '🎁',
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeoSpace.lg,
                0,
                NeoSpace.lg,
                NeoSpace.sm,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Superposition',
                      style: TextStyle(
                        fontFamily: NeoType.display,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        Navigator.pop(context, const _FromGallery()),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Une image'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(
                  NeoSpace.md,
                  0,
                  NeoSpace.md,
                  NeoSpace.lg,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                ),
                itemCount: _emojis.length,
                itemBuilder: (context, i) => InkWell(
                  borderRadius: BorderRadius.circular(NeoRadius.sm),
                  onTap: () => Navigator.pop(context, _emojis[i]),
                  child: Center(
                    child: Text(
                      _emojis[i],
                      style: const TextStyle(fontSize: 30),
                    ),
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

class _FromGallery {
  const _FromGallery();
}
