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
/// écran, et demain dans le feed des Vibes. Le geste est libre dans le fil
/// (voir [TiltableCard]) ; en plein écran, la carte se retourne **par les
/// côtés** et n'écoute aucun glissement ([FlipControl.sides]).
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
    this.display = VibeDisplay.card,
    this.control = FlipControl.gesture,
  });

  final LibraryItem item;

  /// La carte est celle qu'on regarde : sa face visible joue (vidéo).
  final bool active;
  final VoidCallback? onTap;

  /// Ce qui se pose sur les deux faces, dans le cadre. Nul dans le fil : là,
  /// l'identité et les actions vivent dans l'en-tête de la cellule.
  final Widget? overlay;

  /// Où on la regarde — format et marge (voir [VibeDisplay]). Dans un fil
  /// elle est **recadrée** en 4:5, comme Instagram recadre un Reel ; le
  /// contenu, lui, reste un 9:16.
  final VibeDisplay display;

  /// Au doigt (fil, visionneuses) ou par les côtés (plein écran) — voir
  /// [FlipControl]. Par les côtés, une carte sans verso n'écoute rien du
  /// tout : ni retournement, ni inclinaison.
  final FlipControl control;

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
          display: widget.display,
        )
      : VibePhotoFace(
          bytes: m.photoBytes!,
          type: widget.item.cardType,
          overlay: widget.overlay,
          display: widget.display,
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

    // ⚠️ **La structure ne dépend QUE de `hasBack`, constant** — jamais de
    // l'arrivée d'une face. Le recto en attente est une face comme une
    // autre : la carte retournable existe dès la première image, et le
    // geste avec elle. Jusqu'au 2026-09-19, le cadre d'attente du recto
    // n'écoutait rien : balayer une Vibe trop tôt ne la retournait pas — dans
    // le fil, le geste remontait à la couverture et FERMAIT le fil ; en plein
    // écran, il tombait dans le vide. (Le verso suivait déjà cette règle :
    // choisir d'après son arrivée aurait reconstruit le lecteur du recto.)
    final frontFace = front.when(
      loading: () => VibeFaceLoading(
        type: item.cardType,
        overlay: widget.overlay,
        display: widget.display,
      ),
      error: (e, _) => VibeFaceFrame(
        type: item.cardType,
        overlay: widget.overlay,
        display: widget.display,
        child: AspectRatio(
          aspectRatio: widget.display.ratio,
          child: Center(
            child: Text(
              'Cette Vibe n\'est plus disponible.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ),
      ),
      data: (frontFile) =>
          _face(frontFile, item.frontIsVideo, widget.active && _showFront),
    );
    if (!item.hasBack) {
      return _tappable(
        widget.control == FlipControl.sides
            ? frontFace
            : TiltableCard(child: frontFace),
      );
    }
    final backFile = back?.value;
    return FlippableCard(
      control: widget.control,
      onSideChanged: (f) => setState(() => _showFront = f),
      onTap: widget.onTap,
      front: frontFace,
      back: backFile == null
          ? VibeFaceLoading(
              type: item.cardType,
              overlay: widget.overlay,
              display: widget.display,
            )
          : _face(backFile, item.backIsVideo, widget.active && !_showFront),
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
