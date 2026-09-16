import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/crypto/media_open.dart';
import '../../../core/models/library_item.dart';
import '../../../core/video/video_open_trace.dart';
import '../../../core/widgets/vibe_face.dart';
import '../../cards/flippable_card.dart';

/// **Une Vibe publiée, telle qu'on la regarde** : la carte recto/verso,
/// retournable au doigt, avec le cadre de son type — le format qu'on
/// promeut. Même composant dans le fil du profil (en cellule) et en plein
/// écran, et demain dans le feed des Vibes. Le geste est libre partout
/// (voir [TiltableCard] : le défilement se règle aux premiers millimètres).
///
/// Les faces passent par le socle (`contentFaceProvider`) : scellé → clé →
/// clair, la clé prise dans le lot de la bibliothèque du propriétaire.
///
/// [overlay] se pose **dans** chaque face (voir [VibeFaceFrame.overlay]) :
/// c'est ce qui fait que l'identité et les actions du plein écran s'inclinent
/// et se retournent avec la carte, et qu'on les retrouve **identiques sur les
/// deux faces** — c'est le même widget des deux côtés, et ce qu'il affiche
/// (aimé ? enregistré ?) vient des providers, pas de la face.
class VibeCardView extends ConsumerStatefulWidget {
  const VibeCardView({
    super.key,
    required this.item,
    required this.active,
    this.onTap,
    this.overlay,
    this.ratio = kVibeFaceRatio,
  });

  final LibraryItem item;

  /// La carte est celle qu'on regarde : sa face visible joue (vidéo).
  final bool active;
  final VoidCallback? onTap;

  /// Ce qui se pose sur les deux faces, dans le cadre. Nul dans le fil : là,
  /// l'identité et les actions vivent dans l'en-tête de la cellule.
  final Widget? overlay;

  /// Le format d'affichage : 9:16 en plein écran, [kVibeFeedRatio] (4:5) dans
  /// un fil — la Vibe y est **recadrée**, comme Instagram recadre un Reel
  /// (Jay, 2026-09-17). Le contenu, lui, reste un 9:16.
  final double ratio;

  @override
  ConsumerState<VibeCardView> createState() => _VibeCardViewState();
}

class _VibeCardViewState extends ConsumerState<VibeCardView> {
  var _showFront = true;

  ContentFace _spec(bool front) {
    final item = widget.item;
    return (
      contentId: item.id,
      ownerId: item.ownerId,
      bucket: 'library',
      path: front ? item.frontPath : item.backPath!,
      slot: front ? ContentSlot.front : ContentSlot.back,
      isVideo: front ? item.frontIsVideo : item.backIsVideo,
      encrypted: item.encrypted,
      batchOwner: item.ownerId,
      expiresAt: null,
    );
  }

  Widget _face(OpenedMedia m, bool isVideo, bool active) => isVideo
      ? VibeVideoFace(
          media: m,
          type: widget.item.cardType,
          active: active,
          overlay: widget.overlay,
          ratio: widget.ratio,
        )
      : VibePhotoFace(
          bytes: m.photoBytes!,
          type: widget.item.cardType,
          overlay: widget.overlay,
          ratio: widget.ratio,
        );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final front = ref.watch(contentFaceProvider(_spec(true)));
    // Le verso est demandé dès l'ouverture (préchargement) : à dire à la mesure.
    final back = item.hasBack
        ? ref.watch(contentFaceProvider(_spec(false)))
        : null;
    if (item.hasBack && item.backIsVideo) {
      VideoOpenTrace.markPrefetched(item.id, front: false);
    }

    return front.when(
      loading: () => VibeFaceLoading(
        type: item.cardType,
        overlay: widget.overlay,
        ratio: widget.ratio,
      ),
      error: (e, _) => VibeFaceFrame(
        type: item.cardType,
        overlay: widget.overlay,
        child: AspectRatio(
          aspectRatio: widget.ratio,
          child: Center(
            child: Text(
              'Cette Vibe n\'est plus disponible.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ),
      ),
      data: (frontFile) {
        final frontFace = _face(
          frontFile,
          item.frontIsVideo,
          widget.active && _showFront,
        );
        // ⚠️ La structure ne dépend QUE de `hasBack`, constant : choisir
        // d'après l'arrivée du verso changerait le type du widget et
        // reconstruirait le lecteur du recto (voir [VibeFaceLoading]).
        if (!item.hasBack) return _tappable(TiltableCard(child: frontFace));
        final backFile = back?.value;
        return FlippableCard(
          onSideChanged: (f) => setState(() => _showFront = f),
          onTap: widget.onTap,
          front: frontFace,
          back: backFile == null
              ? VibeFaceLoading(
                  type: item.cardType,
                  overlay: widget.overlay,
                  ratio: widget.ratio,
                )
              : _face(backFile, item.backIsVideo, widget.active && !_showFront),
        );
      },
    );
  }

  Widget _tappable(Widget child) => widget.onTap == null
      ? child
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: child,
        );
}
