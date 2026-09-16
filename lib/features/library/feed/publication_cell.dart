import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_view_reporter.dart';
import '../../../core/models/card.dart';
import '../../../core/models/library_item.dart';
import '../../../core/models/profile.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/utils/formats.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/card_type_badge.dart';
import '../../../core/widgets/vibe_face.dart';
import '../../connections/connections_repository.dart';
import '../user_library_screen.dart';
import 'album_carousel.dart';
import 'publication_actions.dart';
import 'vibe_card_view.dart';

/// **Une publication dans un fil** — l'en-tête (qui, quand, **et les
/// actions**), le média, la légende. C'est LA cellule : le fil du profil
/// aujourd'hui, le feed local demain, même widget.
///
/// ⚠️ **Les actions sont en HAUT, sur la ligne du pseudo** (Jay, 2026-09-16).
/// Sous le média, elles ajoutaient une quatrième bande à la cellule et
/// *« on ne peut pas bien voir toutes les parties du contenu sur l'écran en
/// une fois, c'est limite »* — une cellule de Vibe dépassait la hauteur utile
/// d'une cinquantaine de pixels. Remontées, elles ne coûtent plus rien : la
/// ligne d'identité avait la place.
///
/// Deux formats, deux médias : un **album** est un carrousel à son ratio ;
/// une **Vibe** est la carte recto/verso, retournable sur place, dans un
/// cadre haut — un tap l'ouvre en plein écran (`onOpenVibe`).
///
/// [active] : la cellule est celle qu'on regarde (`ActiveItemTracker`) — ses
/// vidéos jouent, et la vue se compte après 3 s d'affichage réel.
class PublicationCell extends ConsumerStatefulWidget {
  const PublicationCell({
    super.key,
    required this.item,
    required this.active,
    required this.onOpenVibe,
    this.onDeleted,
  });

  final LibraryItem item;
  final bool active;
  final VoidCallback onOpenVibe;
  final VoidCallback? onDeleted;

  @override
  ConsumerState<PublicationCell> createState() => _PublicationCellState();
}

class _PublicationCellState extends ConsumerState<PublicationCell> {
  var _page = 0;
  ContentViewReporter? _reporter;

  @override
  void initState() {
    super.initState();
    _reporter = ref.read(contentViewReporterProvider);
    _syncView();
  }

  @override
  void didUpdateWidget(covariant PublicationCell old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _syncView();
  }

  /// La vue ne part qu'après 3 s d'affichage réel (consigne de Jay du
  /// 2026-08-13) : une cellule qui défile sous le doigt n'est pas regardée.
  void _syncView() {
    if (widget.active) {
      _reporter?.watching(widget.item.id);
    } else {
      _reporter?.stopped(widget.item.id);
    }
  }

  @override
  void dispose() {
    _reporter?.stopped(widget.item.id);
    super.dispose();
  }

  ContentFace _spec(LibraryMedia m) => (
    contentId: widget.item.id,
    ownerId: widget.item.ownerId,
    bucket: 'library',
    path: m.path,
    slot: m.slot,
    isVideo: m.isVideo,
    encrypted: widget.item.encrypted,
    batchOwner: widget.item.ownerId,
    expiresAt: null,
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final me = ref.watch(currentUserIdProvider);
    final mine = item.ownerId == me;
    final owner = ref.watch(profileByIdProvider(item.ownerId)).value;

    // Ce que « Enregistrer » copie : l'album → le média affiché ; la Card →
    // ses faces. Lu ici, dans le même provider que l'affichage.
    final String saveId;
    final saveFront = item.isAlbum
        ? ref.watch(contentFaceProvider(_spec(item.media[_page]))).value
        : ref.watch(contentFaceProvider(_spec(item.front))).value;
    final saveBack = !item.isAlbum && item.hasBack
        ? ref.watch(contentFaceProvider(_spec(item.back!))).value
        : null;
    saveId = item.isAlbum ? '${item.id}#${item.media[_page].slot}' : item.id;

    final cell = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(
          item: item,
          owner: owner,
          mine: mine,
          actions: PublicationActions(
            item: item,
            mine: mine,
            saveId: saveId,
            saveFront: saveFront,
            saveBack: saveBack,
            saveFrontIsVideo: item.isAlbum
                ? item.media[_page].isVideo
                : item.frontIsVideo,
            saveBackIsVideo: !item.isAlbum && item.backIsVideo,
            dense: true,
            onDeleted: widget.onDeleted,
          ),
        ),
        if (item.isAlbum)
          AlbumCarousel(
            item: item,
            active: widget.active,
            onPageChanged: (i) => setState(() => _page = i),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NeoSpace.xs),
            child: VibeCardView(
              item: item,
              active: widget.active,
              onTap: widget.onOpenVibe,
            ),
          ),
        if (item.caption != null && item.caption!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.lg,
              0,
              NeoSpace.lg,
              NeoSpace.sm,
            ),
            child: _Caption(author: owner?.displayName, text: item.caption!),
          ),
        const SizedBox(height: NeoSpace.md),
      ],
    );

    // Un album prend toute la largeur (c'est son format). Une Vibe est plus
    // étroite : toute la cellule se cale sur elle, sinon la ligne d'actions
    // commence au bord de l'écran, loin de la carte à laquelle elle
    // appartient.
    if (item.isAlbum) return cell;
    return Center(
      child: SizedBox(
        width: vibeCellWidth(context, item.cardType),
        child: cell,
      ),
    );
  }
}

/// **La largeur d'une Vibe dans un fil.** Elle se déduit de la hauteur qu'on
/// lui accorde — pas plus des trois quarts de l'écran : assez pour la
/// regarder, pas au point de perdre le fil — en tenant compte du cadre
/// (marge + liseré), qui n'est pas de l'image et qui compte pourtant dans la
/// hauteur finale. L'oublier rapetissait la carte d'une trentaine de pixels
/// sous le plafond annoncé.
double vibeCellWidth(BuildContext context, CardType type) {
  final size = MediaQuery.sizeOf(context);
  final chrome = VibeFaceFrame.chrome(type);
  final width = (size.height * 0.72 - chrome) * kVibeFaceRatio + chrome;
  return width.clamp(0.0, size.width - 2 * NeoSpace.lg);
}

/// L'en-tête : avatar, pseudo, date et type — et, à droite, les actions.
///
/// La date et le type passent sur une **deuxième ligne**, sous le pseudo :
/// une cellule de Vibe ne fait que la largeur de la carte, et la ligne doit
/// désormais loger quatre boutons. Sur une seule ligne, le pseudo se réduisait
/// à trois lettres.
class _Header extends StatelessWidget {
  const _Header({
    required this.item,
    required this.owner,
    required this.mine,
    required this.actions,
  });

  final LibraryItem item;
  final Profile? owner;
  final bool mine;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final name = owner?.displayName ?? '';
    final identity = Row(
      children: [
        Avatar(
          stored: owner?.avatarUrl,
          radius: 17,
          fallback: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
        ),
        const SizedBox(width: NeoSpace.sm + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              // ⚠️ Mis à l'échelle plutôt que coupé : une cellule de Vibe est
              // étroite, et « One of One » ne rentre pas toujours à côté de la
              // date. Rogner la pastille du type, c'est perdre l'information ;
              // la réduire un peu, non.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeAgo(item.createdAt),
                      maxLines: 1,
                      style: TextStyle(color: context.muted, fontSize: 12),
                    ),
                    if (!item.isAlbum) ...[
                      const SizedBox(width: NeoSpace.xs + 2),
                      CardTypeBadge(type: item.cardType, fontSize: 9),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        NeoSpace.xs,
        NeoSpace.xs,
        NeoSpace.xs,
      ),
      child: Row(
        children: [
          // Seule l'identité mène au profil : les boutons, à côté, gardent
          // leur propre geste.
          Expanded(
            child: InkWell(
              onTap: owner == null || mine
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => UserLibraryScreen(profile: owner!),
                      ),
                    ),
              child: identity,
            ),
          ),
          actions,
        ],
      ),
    );
  }
}

/// La légende : le nom en gras, puis le texte ; longue, elle se déplie.
class _Caption extends StatefulWidget {
  const _Caption({required this.author, required this.text});
  final String? author;
  final String text;

  @override
  State<_Caption> createState() => _CaptionState();
}

class _CaptionState extends State<_Caption> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: RichText(
        maxLines: _expanded ? null : 3,
        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        text: TextSpan(
          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 14),
          children: [
            if (widget.author != null && widget.author!.isNotEmpty)
              TextSpan(
                text: '${widget.author} ',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            TextSpan(text: widget.text),
          ],
        ),
      ),
    );
  }
}
