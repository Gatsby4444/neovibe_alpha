import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../cards/flippable_card.dart';
import 'publication_viewer_screen.dart';

/// Format d'une mini-card : portrait, comme la card en grand.
const kMiniCardRatio = 9 / 16;

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
/// - **clic** → ouvre en grand (viewer de card, photo ou vidéo).
///
/// [flipAxis] passe en vertical dans le deck, où l'horizontale est déjà prise
/// par le défilement d'une card à l'autre.
class MiniCard extends ConsumerWidget {
  const MiniCard({
    super.key,
    required this.item,
    this.onLongPress,
    this.flipAxis = Axis.horizontal,
    this.decodeWidth = 400,
  });

  final LibraryItem item;
  final VoidCallback? onLongPress;
  final Axis flipAxis;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    final mine = item.ownerId == me;

    // Depuis la refonte du 2026-08-11, une publication est TOUJOURS un contenu
    // à une ou deux faces : la distinction « card » / « photo » a disparu avec
    // la colonne `kind`. Une photo importée est simplement une publication à
    // face unique — même stockage, même règle, même chemin d'affichage.
    final borderColor = item.cardType.color;

    Widget face(Widget child) => _MiniFrame(
      borderColor: borderColor,
      badge: item.cardType.tag,
      badgeColor: item.cardType.color,
      showPublic: item.isPublic && mine,
      child: child,
    );

    final front = face(
      _PublicationThumb(item: item, front: true, decodeWidth: decodeWidth),
    );

    // Une mini-card ne se retourne que si elle a VRAIMENT une deuxième face
    // (correction Jay 2026-07-26 : le retournement avait été mis aussi sur les
    // faces uniques, « ce qui est incohérent »).
    if (!item.hasBack) {
      return AspectRatio(
        aspectRatio: kMiniCardRatio,
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: () => _open(context),
          child: front,
        ),
      );
    }

    return AspectRatio(
      aspectRatio: kMiniCardRatio,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: FlippableCard(
          front: front,
          back: face(
            _PublicationThumb(
              item: item,
              front: false,
              decodeWidth: decodeWidth,
            ),
          ),
          dragAxis: flipAxis,
          // Le tap n'appartient plus au retournement : il ouvre en grand.
          onTap: () => _open(context),
        ),
      ),
    );
  }

  void _open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => PublicationViewerScreen(item: item)),
  );
}

/// Vignette d'une face de publication.
///
/// Les octets sont chiffrés : la vignette passe donc par le même chemin que la
/// lecture plein écran (scellé → clé → clair), avec la clé prise dans le LOT
/// de la bibliothèque — sans quoi chaque vignette coûterait un appel serveur.
class _PublicationThumb extends ConsumerWidget {
  const _PublicationThumb({
    required this.item,
    required this.front,
    required this.decodeWidth,
  });

  final LibraryItem item;
  final bool front;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isVideo = front ? item.frontIsVideo : item.backIsVideo;
    final face = ref.watch(
      contentFaceProvider((
        contentId: item.id,
        ownerId: item.ownerId,
        bucket: 'library',
        path: front ? item.frontPath : item.backPath!,
        front: front,
        isVideo: isVideo,
        encrypted: item.encrypted,
        // Une grille : les clés viennent du lot, pas une par vignette.
        batchOwner: item.ownerId,
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
          // Une vignette de vidéo demanderait d'extraire une image du flux :
          // c'est le chantier « vignettes vidéo » (RAPPELS #4), pas celui-ci.
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
