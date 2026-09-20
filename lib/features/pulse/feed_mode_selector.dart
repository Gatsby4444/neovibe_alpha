import 'package:flutter/material.dart';

import 'pulse_repository.dart';

/// **Le sélecteur du fil** (Jay, 2026-09-20) : rien que le mode courant et
/// une flèche, dans la typo de l'app ; le menu qui se déroule dessous n'a
/// **pas de fond** — trois textes, blancs sur un plein écran, noirs sur un
/// fil clair, cliquables. *« Pro et épuré dans la DA NeoVibe. »*
class FeedModeSelector extends StatelessWidget {
  const FeedModeSelector({
    super.key,
    required this.mode,
    required this.onChanged,
    required this.light,
  });

  final FeedMode mode;
  final ValueChanged<FeedMode> onChanged;

  /// Encre blanche (plein écran) ou celle du thème (fil clair).
  final bool light;

  Color _ink(BuildContext context) =>
      light ? Colors.white : Theme.of(context).colorScheme.onSurface;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    final ink = _ink(context);
    final style = (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
        .copyWith(color: ink, fontWeight: FontWeight.w600);
    final choix = await showMenu<FeedMode>(
      context: context,
      position: RelativeRect.fromLTRB(origin.dx, origin.dy, origin.dx, 0),
      // Pas de fond, pas d'ombre : les textes seuls.
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      items: [
        for (final m in FeedMode.values)
          PopupMenuItem(
            value: m,
            height: 40,
            child: Text(
              m.label,
              style: style.copyWith(
                color: m == mode ? ink : ink.withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
    if (choix != null && choix != mode) onChanged(choix);
  }

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    final style = (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
        .copyWith(color: ink, fontWeight: FontWeight.w700);
    return Builder(
      builder: (ctx) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(ctx),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(mode.label, style: style),
              Icon(Icons.expand_more, size: 20, color: ink),
            ],
          ),
        ),
      ),
    );
  }
}
