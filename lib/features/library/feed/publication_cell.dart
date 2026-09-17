import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_view_reporter.dart';
import '../../../core/models/library_item.dart';
import '../../../core/models/profile.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/utils/formats.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/card_type_badge.dart';
import '../../../core/widgets/like_burst.dart';
import '../../../core/widgets/press_veil.dart';
import '../../../core/widgets/vibe_face.dart';
import '../../connections/connections_repository.dart';
import 'album_carousel.dart';
import 'publication_actions.dart';
import 'publication_caption.dart';
import 'vibe_card_view.dart';
import '../open_profile.dart';

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
/// Deux formats, deux médias, **la même largeur** : un **album** est un
/// carrousel au ratio choisi à la publication (4:5, 1:1 ou 1,91:1) ; une
/// **Vibe** est la carte recto/verso, retournable sur place, **recadrée en
/// 4:5** — exactement ce que fait Instagram d'un Reel dans le fil classique
/// (Jay, 2026-09-17). Un tap l'ouvre en plein écran, à son vrai format
/// (`onOpenVibe`).
///
/// [onOpen] : ouvrir en grand — le plein écran des Vibes ou celui des Flows,
/// selon le format. Un carrousel n'en a pas : il se lit ici.
///
/// [active] : la cellule est celle qu'on regarde (`ActiveItemTracker`) — ses
/// vidéos jouent, et la vue se compte après 3 s d'affichage réel.
class PublicationCell extends ConsumerStatefulWidget {
  const PublicationCell({
    super.key,
    required this.item,
    required this.active,
    required this.onOpen,
    this.onDeleted,
  });

  final LibraryItem item;
  final bool active;
  final VoidCallback onOpen;
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
    final saveFront = item.isPublication
        ? ref.watch(contentFaceProvider(_spec(item.media[_page]))).value
        : ref.watch(contentFaceProvider(_spec(item.front))).value;
    final saveBack = !item.isPublication && item.hasBack
        ? ref.watch(contentFaceProvider(_spec(item.back!))).value
        : null;
    saveId = item.isPublication
        ? '${item.id}#${item.media[_page].slot}'
        : item.id;

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
            saveFrontIsVideo: item.isPublication
                ? item.media[_page].isVideo
                : item.frontIsVideo,
            saveBackIsVideo: !item.isPublication && item.backIsVideo,
            dense: true,
            onDeleted: widget.onDeleted,
          ),
        ),
        // Aimer au geste : double tap **et** appui long sur une
        // publication, appui long seul sur une Vibe — le tap y ouvre déjà le
        // plein écran, et un double tap le retarderait (Jay, 2026-09-17).
        LikeBurst(
          contentId: item.id,
          doubleTap: item.isPublication,
          child: item.isPublication
              ? AlbumCarousel(
                  item: item,
                  active: widget.active,
                  onPageChanged: (i) => setState(() => _page = i),
                )
              : VibeCardView(
                  item: item,
                  active: widget.active,
                  onTap: widget.onOpen,
                  display: VibeDisplay.feed,
                ),
        ),
        // ⚠️ **Pas de légende sur une Vibe** (Jay, 2026-09-17) : une Vibe
        // n'est pas une publication qu'on commente, c'est une carte — le
        // texte y entrera par son propre éditeur, écrit sur l'image.
        if (item.isPublication && (item.caption?.isNotEmpty ?? false))
          PublicationCaption(text: item.caption!, font: item.captionFont),
        const SizedBox(height: NeoSpace.md),
      ],
    );

    // Album comme Vibe : **toute la largeur**. Depuis que la Vibe est
    // recadree en 4:5, les deux formats font la meme largeur - la cellule
    // n'a plus a se caler sur une carte plus etroite que l'ecran, et tout
    // (en-tete, actions, legende) retrouve le meme bord gauche.
    return cell;
  }
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
                    if (!item.isPublication) ...[
                      const SizedBox(width: NeoSpace.xs + 2),
                      CardTypeBadge(type: item.cardType, fontSize: 9),
                    ] else if (item.isFlow) ...[
                      // La requalification se voit : l'app a décidé toute
                      // seule que cette vidéo seule est un Flow.
                      const SizedBox(width: NeoSpace.xs + 2),
                      const FlowBadge(),
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
          // leur propre geste. Le voile dit au doigt qu'il a été entendu —
          // l'onde d'un InkWell se peignait DERRIÈRE l'avatar et le pseudo,
          // donc elle ne se voyait pas (Jay, 2026-09-17).
          Expanded(
            child: PressVeil(
              onTap: owner == null || mine
                  ? null
                  : () => openProfile(context, owner!),
              child: identity,
            ),
          ),
          actions,
        ],
      ),
    );
  }
}
