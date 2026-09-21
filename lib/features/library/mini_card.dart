import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/content/video_poster.dart';
import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/vibe_face.dart';
import '../../core/widgets/reel_route.dart';
import '../cards/flippable_card.dart';
import 'feed/vibes_reel_screen.dart';

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
///   (le plein écran, posé sur cette Vibe). Sans [onTap], la Vibe s'ouvre
///   seule en plein écran.
class MiniCard extends ConsumerWidget {
  const MiniCard({
    super.key,
    required this.item,
    this.onTap,
    this.onLongPress,
    this.decodeWidth = 400,
    this.ratio = kVibeFaceRatio,
  });

  final LibraryItem item;

  /// Le format de la vignette : celui de la Vibe, 9:16 — *« les voir à leur
  /// vrai format est ce qui le dit »* (Jay, 2026-09-17). Le 4:5 de la grille
  /// mêlée est parti avec les albums (2026-09-21).
  final double ratio;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    final mine = item.ownerId == me;

    // Depuis la refonte du 2026-08-11, une publication est TOUJOURS un contenu
    // à une ou deux faces. Le liseré dit le TYPE (standard, oneshot, bereal),
    // comme avant le feed mêlé du 2026-09-20 — où il disait la nature ; il
    // n'y en a plus qu'une. `displayColor` : la vignette se pose sur
    // l'habillage de l'app, pas sur une photo. En thème clair, `color` y est
    // illisible pour la standard.
    final borderColor = item.cardType.displayColor(context);

    Widget face(Widget child) => _MiniFrame(
      borderColor: borderColor,
      badge: item.cardType.tag,
      badgeColor: item.cardType.displayColor(context),
      showPublic: item.isPublic && mine,
      child: child,
    );

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
          onHorizontalDragStart: _zoneNeutre,
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

  /// **Une zone neutre sous chaque mini** (Jay, 2026-09-18) : balayer une
  /// vignette qui n'a pas de verso — une face unique — ne fait **rien**, au
  /// lieu de remonter au balayage de l'écran et
  /// de changer de section. Une mini à deux faces absorbe déjà ce geste pour
  /// se retourner ; celles-ci l'absorbent pour ne rien faire, et la grille
  /// se comporte pareil sous le doigt quelle que soit la case.
  static void _zoneNeutre(DragStartDetails _) {}

  void _open(BuildContext context) {
    if (onTap != null) {
      onTap!();
      return;
    }
    Navigator.of(context).push(
      ReelRoute(
        builder: (_) => VibesReelScreen(vibes: [item], initialIndex: 0),
      ),
    );
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

  ContentFace get _spec => (
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
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final face = ref.watch(contentFaceProvider(_spec));
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
          // Une vidéo : sa couverture est extraite sur l'appareil, une
          // fois, de la vidéo scellée (`video_poster.dart`, 2026-09-20).
          ? _VideoPoster(spec: _spec, decodeWidth: decodeWidth)
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
    this.badgeColor,
    this.showPublic = false,
  });

  final Widget child;
  final Color borderColor;
  final String? badge;
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
            if (badge != null)
              Positioned(
                left: 4,
                bottom: 4,
                child: _Chip(text: badge!, color: badgeColor ?? Colors.white),
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
  const _Chip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// La couverture d'une face vidéo, extraite et rescellée sur l'appareil.
class _VideoPoster extends ConsumerWidget {
  const _VideoPoster({required this.spec, required this.decodeWidth});

  final ContentFace spec;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = ref.watch(videoPosterProvider(spec));
    return Stack(
      fit: StackFit.expand,
      children: [
        poster.when(
          loading: () => ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          // Une vidéo dont on ne tire pas d'image : l'icône d'avant.
          error: (e, _) => Tooltip(
            message: '$e',
            child: const _ThumbPlaceholder(icon: Icons.videocam),
          ),
          data: (bytes) => Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                const _ThumbPlaceholder(icon: Icons.broken_image),
          ),
        ),
        // Le signe « vidéo », discret, en bas à gauche.
        const Positioned(
          left: 6,
          bottom: 6,
          child: Icon(
            Icons.play_arrow_rounded,
            size: 18,
            color: Colors.white,
            shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
          ),
        ),
      ],
    );
  }
}
