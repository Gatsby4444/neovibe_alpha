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

/// **Une publication dans un fil** — c'est LA cellule : le fil du profil
/// aujourd'hui, le feed local demain, même widget. Deux dispositions, selon
/// ce qu'on montre (Jay, 2026-09-19, sur le modèle du fil d'Instagram) :
///
/// | | **publication / Flow** | **Vibe** |
/// |---|---|---|
/// | en-tête | avatar, pseudo, menu « … » | avatar, pseudo, date, type, **et les actions** |
/// | sous le média | points du carrousel, **barre** aimer · partager … enregistrer, légende, date | — |
///
/// Pour une Vibe, les actions restent en HAUT, sur la ligne du pseudo (Jay,
/// 2026-09-16 : sous la carte, la cellule ne tenait plus dans un écran) — et
/// Jay a redit le 2026-09-19 : *« pour les cards on ne touche pas »*.
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
    this.onChanged,
  });

  final LibraryItem item;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback? onDeleted;

  /// La publication a changé (sa légende) : l'écran remplace son exemplaire.
  final ValueChanged<LibraryItem>? onChanged;

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

    final actions = PublicationActions(
      item: item,
      mine: mine,
      saveId: saveId,
      saveFront: saveFront,
      saveBack: saveBack,
      saveFrontIsVideo: item.isPublication
          ? item.media[_page].isVideo
          : item.frontIsVideo,
      saveBackIsVideo: !item.isPublication && item.backIsVideo,
      dense: !item.isPublication,
      bar: item.isPublication,
      onDeleted: widget.onDeleted,
      onChanged: widget.onChanged,
    );

    // Aimer au geste : double tap **et** appui long, publication comme Vibe
    // (Jay, 2026-09-19 : *« rétablis le double tap pour liker sur les cards
    // du fil »*). Le tap simple — ouvrir en plein écran — attend donc
    // ~300 ms un éventuel second appui ; Jay l'accepte ICI, dans le fil.
    // En plein écran, non (RAPPELS #147).
    final media = LikeBurst(
      contentId: item.id,
      doubleTap: true,
      child: item.isPublication
          ? AlbumCarousel(
              item: item,
              active: widget.active,
              onPageChanged: (i) => setState(() => _page = i),
              // Un Flow s'ouvre en plein écran d'un tap, comme une Vibe
              // (Jay, 2026-09-19). Un carrousel, lui, se lit ici.
              onTap: item.isFlow ? widget.onOpen : null,
            )
          : VibeCardView(
              item: item,
              active: widget.active,
              onTap: widget.onOpen,
              display: VibeDisplay.feed,
            ),
    );

    // Une Vibe : l'en-tête porte tout, la carte suit, rien dessous.
    if (!item.isPublication) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(item: item, owner: owner, mine: mine, actions: actions),
          media,
          const SizedBox(height: NeoSpace.md),
        ],
      );
    }

    // Une publication ou un Flow : le modèle d'Instagram — l'en-tête ne porte
    // que le menu ; sous le média, les points du carrousel, la barre
    // d'actions, la légende, la date.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(
          item: item,
          owner: owner,
          mine: mine,
          actions: PublicationMenu(
            item: item,
            mine: mine,
            color: Theme.of(context).colorScheme.onSurface,
            onDeleted: widget.onDeleted,
            onChanged: widget.onChanged,
          ),
        ),
        media,
        if (item.media.length > 1)
          _Dots(count: item.media.length, current: _page),
        actions,
        if (item.caption?.isNotEmpty ?? false)
          PublicationCaption(text: item.caption!, font: item.captionFont),
        Padding(
          padding: const EdgeInsets.fromLTRB(NeoSpace.md, NeoSpace.xs, 0, 0),
          child: Text(
            timeAgo(item.createdAt),
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
        ),
        const SizedBox(height: NeoSpace.md),
      ],
    );
  }
}

/// Les points d'un carrousel, sous le média : celui de l'image courante est
/// encré, les autres effacés.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: NeoSpace.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: i == current ? 6 : 5,
              height: i == current ? 6 : 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == current ? ink : ink.withValues(alpha: 0.25),
              ),
            ),
        ],
      ),
    );
  }
}

/// L'en-tête : avatar, pseudo — et, à droite, [actions] (les quatre boutons
/// d'une Vibe, le seul menu d'une publication).
///
/// Pour une **Vibe**, la date et le type passent sur une **deuxième ligne**,
/// sous le pseudo : la ligne doit loger quatre boutons, et sur une seule le
/// pseudo se réduisait à trois lettres. Pour une **publication**, une seule
/// ligne — la date est sous la légende, comme sur Instagram. Jay note qu'un
/// élément textuel viendra peut-être un jour sous le pseudo, pour
/// harmoniser (Instagram y met « Suggestions » ou la musique).
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
              if (!item.isPublication)
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
                      const SizedBox(width: NeoSpace.xs + 2),
                      CardTypeBadge(type: item.cardType, fontSize: 9),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // La requalification se voit : l'app a décidé toute seule que cette
        // vidéo seule est un Flow.
        if (item.isFlow) ...[
          const SizedBox(width: NeoSpace.sm),
          const FlowBadge(),
        ],
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        NeoSpace.md,
        item.isPublication ? NeoSpace.sm : NeoSpace.xs,
        NeoSpace.xs,
        item.isPublication ? NeoSpace.sm : NeoSpace.xs,
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
