import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/vibe_face.dart';
import '../cards/flippable_card.dart';
import 'feed/publications_feed_screen.dart';

/// **Le format d'une vignette de la grille du profil : 4:5.**
///
/// Choisi par Jay le 2026-09-17, « comme Instagram aujourd'hui ». Avant, la
/// grille était au format de la Card (9:16) — cohérent tant que tout était une
/// Card, brutal depuis qu'une publication peut être un paysage 1,91:1 : il
/// n'en serait resté qu'une lame verticale. Une Vibe y est **recadrée**, comme
/// elle l'est dans le fil ([kVibeFeedRatio]) et comme Instagram recadre un
/// Reel dans sa grille.
///
/// ⚠️ Ce n'est PAS le format d'une Card. Une vignette de Card (les
/// Enregistrements, l'aperçu d'un partage dans le chat) reste en
/// [kVibeFaceRatio] : là, l'objet montré est la carte elle-même.
const kMiniCardRatio = kVibeFeedRatio;

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(icon, color: context.faint, size: 26)),
    );
  }
}

// ---------------------------------------------------------------------------
// Mini-card
// ---------------------------------------------------------------------------

/// Prévisualisation d'une publication au **format card** (consigne Jay
/// 2026-07-25, en remplacement des vignettes carrées).
///
/// Gestes, dans les mots de Jay : « le geste qui swipe c'est le swipe, et le
/// geste qui ouvre c'est le clic ».
/// - **swipe** (horizontal par défaut) → retourne la mini-card sur place ;
/// - **clic** → [onTap] ; la grille qui nous contient décide où ça mène
///   (le fil du profil, posé sur cette publication — 2026-09-15). Sans
///   [onTap], la publication s'ouvre seule dans ce même fil.
class MiniCard extends ConsumerWidget {
  const MiniCard({
    super.key,
    required this.item,
    this.onTap,
    this.onLongPress,
    this.decodeWidth = 400,
    this.ratio = kMiniCardRatio,
  });

  final LibraryItem item;

  /// Le format de la vignette. [kMiniCardRatio] (4:5) dans la grille de
  /// tout ; **[kVibeFaceRatio] (9:16) dans l'onglet Vibes** — là, on ne
  /// montre que des cartes, et les voir à leur vrai format est ce qui le dit
  /// (Jay, 2026-09-17).
  final double ratio;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    final mine = item.ownerId == me;

    // Depuis la refonte du 2026-08-11, une publication est TOUJOURS un contenu
    // à une ou deux faces : la distinction « card » / « photo » a disparu avec
    // la colonne `kind`. Une photo importée est simplement une publication à
    // face unique — même stockage, même règle, même chemin d'affichage.
    // `displayColor` : la vignette se pose sur l'habillage de l'app, pas sur
    // une photo. En thème clair, `color` y est illisible pour la standard.
    final borderColor = item.cardType.displayColor(context);

    Widget face(Widget child) => _MiniFrame(
      borderColor: borderColor,
      badge: item.cardType.tag,
      badgeColor: item.cardType.displayColor(context),
      showPublic: item.isPublic && mine,
      child: child,
    );

    // Un ALBUM (2026-09-15) : même cadre, même liseré, même format — Jay :
    // « tout dans l'affichage de la bibliothèque doit être identique ». Ce qui
    // change : la couverture est le premier média (l'image de couverture pour
    // une vidéo) et la pastille dit combien il y en a.
    if (item.isPublication) {
      final cover = item.media.first;
      final thumb = cover.isVideo && cover.posterPath != null
          ? _PublicationThumb(
              item: item,
              slot: ContentSlot.poster(cover.slot),
              path: cover.posterPath!,
              isVideo: false,
              decodeWidth: decodeWidth,
            )
          : _PublicationThumb(
              item: item,
              slot: cover.slot,
              path: cover.path,
              isVideo: cover.isVideo,
              decodeWidth: decodeWidth,
            );
      return AspectRatio(
        aspectRatio: ratio,
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: () => _open(context),
          child: _MiniFrame(
            borderColor: borderColor,
            badgeIcon: item.media.length > 1
                ? Icons.collections_outlined
                : cover.isVideo
                ? Icons.play_arrow_rounded
                : null,
            badge: item.media.length > 1 ? '${item.media.length}' : null,
            badgeColor: Colors.white,
            showPublic: item.isPublic && mine,
            child: thumb,
          ),
        ),
      );
    }

    final front = face(
      _PublicationThumb(
        item: item,
        slot: ContentSlot.front,
        path: item.frontPath,
        isVideo: item.frontIsVideo,
        decodeWidth: decodeWidth,
      ),
    );

    // Une mini-card ne se retourne que si elle a VRAIMENT une deuxième face
    // (correction Jay 2026-07-26 : le retournement avait été mis aussi sur les
    // faces uniques, « ce qui est incohérent »).
    if (!item.hasBack) {
      return AspectRatio(
        aspectRatio: ratio,
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: () => _open(context),
          child: front,
        ),
      );
    }

    return AspectRatio(
      aspectRatio: ratio,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: FlippableCard(
          front: front,
          back: face(
            _PublicationThumb(
              item: item,
              slot: ContentSlot.back,
              path: item.backPath!,
              isVideo: item.backIsVideo,
              decodeWidth: decodeWidth,
            ),
          ),
          dragAxis: Axis.horizontal,
          // Le tap n'appartient plus au retournement : il ouvre en grand.
          onTap: () => _open(context),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    if (onTap != null) {
      onTap!();
      return;
    }
    openPublications(context, items: [item], initialIndex: 0);
  }
}

/// Vignette d'une face de publication.
///
/// Les octets sont chiffrés : la vignette passe donc par le même chemin que la
/// lecture plein écran (scellé → clé → clair), avec la clé prise dans le LOT
/// de la bibliothèque — sans quoi chaque vignette coûterait un appel serveur.
class _PublicationThumb extends ConsumerWidget {
  const _PublicationThumb({
    required this.item,
    required this.slot,
    required this.path,
    required this.isVideo,
    required this.decodeWidth,
  });

  final LibraryItem item;
  final int slot;
  final String path;
  final bool isVideo;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final face = ref.watch(
      contentFaceProvider((
        contentId: item.id,
        ownerId: item.ownerId,
        bucket: 'library',
        path: path,
        slot: slot,
        isVideo: isVideo,
        encrypted: item.encrypted,
        // Une grille : les clés viennent du lot, pas une par vignette.
        batchOwner: item.ownerId,
        // Permanente (décision de Jay, 2026-08-11) : rien à faire expirer.
        expiresAt: null,
      )),
    );
    // Trois états, trois rendus DISTINCTS. Un chargement qui ressemble à un
    // échec est le défaut qui a rendu la panne du 2026-08-11 illisible : des
    // tuiles grises, impossible de dire si ça charge ou si c'est cassé.
    return face.when(
      loading: () => Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          const Center(
            child: SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
          ),
        ],
      ),
      error: (e, _) => Tooltip(
        message: '$e',
        child: const _ThumbPlaceholder(icon: Icons.error_outline),
      ),
      data: (media) => isVideo
          // Une vignette de vidéo de CARD demanderait d'extraire une image du
          // flux : c'est le chantier « vignettes vidéo » (RAPPELS #4), pas
          // celui-ci. Une vidéo d'ALBUM a sa couverture (`posterPath`).
          ? const _ThumbPlaceholder(icon: Icons.videocam)
          // `cacheWidth` : les fichiers font 720×1280 et les vignettes
          // quelques centaines de pixels — décoder en pleine résolution
          // coûtait de la mémoire et du temps pour rien.
          : Image.memory(
              media.photoBytes!,
              fit: BoxFit.cover,
              cacheWidth: decodeWidth,
              errorBuilder: (_, _, _) =>
                  const _ThumbPlaceholder(icon: Icons.broken_image),
            ),
    );
  }
}

/// Cadre commun aux deux faces : coins arrondis, liseré de la couleur du type,
/// tag du type et badge « Public ».
class _MiniFrame extends StatelessWidget {
  const _MiniFrame({
    required this.child,
    required this.borderColor,
    this.badge,
    this.badgeIcon,
    this.badgeColor,
    this.showPublic = false,
  });

  final Widget child;
  final Color borderColor;
  final String? badge;

  /// Album : l'icône « plusieurs » ou « vidéo » devant le compte.
  final IconData? badgeIcon;
  final Color? badgeColor;
  final bool showPublic;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border.all(color: borderColor, width: 1.6),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          // L'ombre portée était un noir à 54 % : correct sur fond sombre,
          // sale sur fond clair. Elle s'allège avec le thème (2026-08-10).
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.54
                  : 0.16,
            ),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10.4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (badge != null || badgeIcon != null)
              Positioned(
                left: 4,
                bottom: 4,
                child: _Chip(
                  text: badge,
                  icon: badgeIcon,
                  color: badgeColor ?? Colors.white,
                ),
              ),
            if (showPublic)
              const Positioned(
                right: 4,
                top: 4,
                child: _Chip(text: 'Public', color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({this.text, this.icon, required this.color});
  final String? text;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, size: 11, color: color),
          if (icon != null && text != null) const SizedBox(width: 2),
          if (text != null)
            Text(
              text!,
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}
