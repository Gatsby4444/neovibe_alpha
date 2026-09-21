import 'package:flutter/material.dart';

import '../../core/models/library_item.dart';
import '../../core/publish/publish_bridge.dart';
import '../../core/theme.dart';
import '../../core/widgets/anchor_scope.dart';
import '../../core/widgets/reel_route.dart';
import '../../core/widgets/vibe_face.dart';
import 'feed/vibes_reel_screen.dart';
import 'mini_card.dart';
import 'pending_cell.dart';

/// **La grille d'un profil : ses Vibes, à leur format** (9:16), trois par
/// ligne ; un appui ouvre **le plein écran** ([VibesReelScreen]), posé sur
/// la case touchée.
///
/// Du 2026-09-17 au 2026-09-21, c'étaient trois onglets (Tout / Vibes /
/// Flows), parce que la bibliothèque mêlait trois formats. Les albums et les
/// Flows sont sortis du MVP (Jay, 2026-09-21 : *« un éditeur pour un
/// format »*) ; il reste l'onglet Vibes, seul, sous son nom de toujours.
/// *« Les voir à leur vrai format est ce qui le dit »* (Jay, 2026-09-17).
class PublicationsTabs extends StatefulWidget {
  const PublicationsTabs({
    super.key,
    required this.items,
    required this.emptyMessage,
    this.pending = const [],
    this.padding = const EdgeInsets.fromLTRB(10, 0, 10, 80),
    this.onLongPress,
  });

  /// Toutes les Vibes du profil, dans l'ordre.
  final List<LibraryItem> items;

  /// **Les Vibes en cours d'envoi** (mon profil seulement), en tête de la
  /// grille avec leur avancement — celles qui sont déjà dans [items] n'y
  /// sont pas montrées deux fois.
  final List<PendingPublication> pending;

  /// Ce qu'on lit quand il n'y a rien du tout.
  final String emptyMessage;

  final EdgeInsets padding;

  /// Appui long sur une case (retirer, sur mon propre profil).
  final void Function(LibraryItem item)? onLongPress;

  @override
  State<PublicationsTabs> createState() => _PublicationsTabsState();
}

class _PublicationsTabsState extends State<PublicationsTabs> {
  final _anchorsKey = GlobalKey<AnchorScopeState>();

  /// Le plein écran demande à voir ce contenu : la case défile en vue, au
  /// milieu — c'est là que la rétraction viendra se poser.
  void _reveal(String id) {
    final ctx = _anchorsKey.currentState?.contextOf(id);
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final liste = widget.items;
    final ids = {for (final i in liste) i.id};
    final enCours = widget.pending.where((p) => !ids.contains(p.id)).toList();
    const ratio = kVibeFaceRatio;

    return AnchorScope(
      key: _anchorsKey,
      onReveal: _reveal,
      child: liste.isEmpty && enCours.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                widget.emptyMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted),
              ),
            )
          : GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: widget.padding,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: ratio,
              ),
              itemCount: enCours.length + liste.length,
              itemBuilder: (context, index) {
                // Les envois en cours d'abord : c'est là qu'ils apparaîtront.
                if (index < enCours.length) {
                  return PendingCell(item: enCours[index], ratio: ratio);
                }
                final i = index - enCours.length;
                return Anchored(
                  id: liste[i].id,
                  child: MiniCard(
                    item: liste[i],
                    ratio: ratio,
                    onTap: () => _ouvrir(liste, i),
                    onLongPress: widget.onLongPress == null
                        ? null
                        : () => widget.onLongPress!(liste[i]),
                  ),
                );
              },
            ),
    );
  }

  void _ouvrir(List<LibraryItem> liste, int index) {
    Navigator.of(context).push(
      ReelRoute(
        builder: (_) => VibesReelScreen(
          vibes: liste,
          initialIndex: index,
          anchors: _anchorsKey.currentState,
        ),
      ),
    );
  }
}
