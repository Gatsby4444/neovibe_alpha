import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../cards/card_media_cache.dart';
import '../cards/card_viewer_screen.dart';
import '../cards/flippable_card.dart';
import '../conversations/video_player_screen.dart';
import 'library_repository.dart';
import 'photo_viewer_screen.dart';

/// Format d'une mini-card : portrait, comme la card en grand.
const kMiniCardRatio = 9 / 16;

// ---------------------------------------------------------------------------
// Résolution d'une vignette : LOCAL d'abord, réseau en repli
// ---------------------------------------------------------------------------

/// De quoi retrouver une vignette. `mine` conditionne la lecture locale : le
/// cache `own/` ne contient que MES contenus.
typedef ThumbSpec = ({
  String bucket, // 'cards' | 'library'
  String path, // chemin dans le bucket
  String? cardId, // face de card : identifiant de la card
  bool front, // face de card : recto ?
  bool isVideo,
  bool mine,
});

/// Fichier local si disponible, sinon URL signée.
typedef ThumbSource = ({File? file, String? url});

/// Cause des lenteurs constatées par Jay (2026-07-25) : la grille demandait une
/// URL signée PUIS téléchargeait l'image pleine résolution, à chaque vignette,
/// alors que mes propres contenus sont déjà sur l'appareil (`CardMediaCache`,
/// dossier `own/`). On lit donc le local d'abord ; le réseau n'est plus qu'un
/// repli (contenu d'un autre, ou mien mais évincé par le quota).
final thumbSourceProvider = FutureProvider.family<ThumbSource, ThumbSpec>((
  ref,
  spec,
) async {
  if (spec.mine) {
    final cache = ref.read(cardMediaCacheProvider);
    final local = spec.cardId != null
        ? await cache.tryOwnFace(
            spec.cardId!,
            front: spec.front,
            isVideo: spec.isVideo,
          )
        : await cache.tryOwnMedia(spec.path);
    if (local != null) return (file: local, url: null);
  }
  final url = await ref
      .read(supabaseProvider)
      .storage
      .from(spec.bucket)
      .createSignedUrl(spec.path, 3600);
  return (file: null, url: url);
});

/// Image d'une face, résolue par [thumbSourceProvider].
///
/// `cacheWidth` : les fichiers font 720×1280 et les vignettes quelques
/// centaines de pixels — décoder en pleine résolution coûtait de la mémoire
/// et du temps pour rien.
class Thumb extends ConsumerWidget {
  const Thumb({super.key, required this.spec, this.decodeWidth = 400});

  final ThumbSpec spec;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Une face vidéo ne se décode pas comme une image (« Invalid image data »,
    // journal du 2026-07-14) : pas de vignette tant qu'on ne produit pas une
    // image de couverture à la capture.
    if (spec.isVideo) return const _ThumbPlaceholder(icon: Icons.videocam);

    final source = ref.watch(thumbSourceProvider(spec));
    return source.when(
      loading: () => const ColoredBox(color: NeoTheme.surface2),
      error: (_, _) => const _ThumbPlaceholder(icon: Icons.broken_image),
      data: (s) {
        if (s.file != null) {
          return Image.file(
            s.file!,
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            errorBuilder: (_, _, _) =>
                const _ThumbPlaceholder(icon: Icons.broken_image),
          );
        }
        return Image.network(
          s.url!,
          fit: BoxFit.cover,
          cacheWidth: decodeWidth,
          errorBuilder: (_, _, _) =>
              const _ThumbPlaceholder(icon: Icons.broken_image),
        );
      },
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: NeoTheme.surface2,
      child: Center(child: Icon(icon, color: Colors.white38, size: 26)),
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
    final card = item.card;
    final isCard = item.kind == 'card' && card != null;

    final borderColor = isCard
        ? card.type.color
        : Colors.white.withValues(alpha: .14);

    Widget face(Widget child) => _MiniFrame(
      borderColor: borderColor,
      badge: isCard ? card.type.tag : null,
      badgeColor: isCard ? card.type.color : null,
      showPublic: item.isPublic && mine,
      child: child,
    );

    // Cas dégradé : entrée de type « card » dont la card n'a pas été jointe
    // (supprimée, ou refusée par la RLS) — rien à afficher, pas de plantage.
    if (!isCard && item.mediaPath == null) {
      return AspectRatio(
        aspectRatio: kMiniCardRatio,
        child: _MiniFrame(
          borderColor: borderColor,
          child: const _ThumbPlaceholder(icon: Icons.help_outline),
        ),
      );
    }

    final front = face(
      isCard
          ? Thumb(
              spec: (
                bucket: 'cards',
                path: card.frontPath,
                cardId: card.id,
                front: true,
                isVideo: card.frontIsVideo,
                mine: mine,
              ),
              decodeWidth: decodeWidth,
            )
          : Thumb(
              spec: (
                bucket: 'library',
                path: item.mediaPath!,
                cardId: null,
                front: true,
                isVideo: item.kind == 'video',
                mine: mine,
              ),
              decodeWidth: decodeWidth,
            ),
    );

    // Verso : la deuxième face pour une card à deux faces ; sinon une fiche
    // sobre (légende + date), pour que le geste ait toujours une réponse.
    final Widget back;
    if (isCard && card.backPath != null) {
      back = face(
        Thumb(
          spec: (
            bucket: 'cards',
            path: card.backPath!,
            cardId: card.id,
            front: false,
            isVideo: card.backIsVideo,
            mine: mine,
          ),
          decodeWidth: decodeWidth,
        ),
      );
    } else {
      back = face(_MiniBack(item: item, accent: borderColor));
    }

    return AspectRatio(
      aspectRatio: kMiniCardRatio,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: FlippableCard(
          front: front,
          back: back,
          dragAxis: flipAxis,
          // Le tap n'appartient plus au retournement : il ouvre en grand.
          onTap: () => _open(context, ref),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final card = item.card;
    if (item.kind == 'card' && card != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CardViewerScreen(card: card, fromLibrary: true),
        ),
      );
      return;
    }
    final path = item.mediaPath;
    if (path == null) return;
    final url = await ref.read(libraryRepositoryProvider).mediaUrl(path);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => item.kind == 'video'
            ? VideoPlayerScreen(url: url)
            : PhotoViewerScreen(url: url, caption: item.caption),
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
        color: NeoTheme.surface2,
        border: Border.all(color: borderColor, width: 1.6),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3)),
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

/// Verso d'une publication sans deuxième face : légende et date.
class _MiniBack extends StatelessWidget {
  const _MiniBack({required this.item, required this.accent});
  final LibraryItem item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final d = item.createdAt.toLocal();
    final date =
        '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
    return Container(
      color: NeoTheme.surface1,
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.kind == 'video' ? Icons.videocam : Icons.photo,
            color: accent,
            size: 20,
          ),
          const SizedBox(height: 8),
          if (item.caption != null && item.caption!.isNotEmpty)
            Text(
              item.caption!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          const Spacer(),
          Text(
            date,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
