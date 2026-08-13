import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/media_open.dart';
import '../../core/models/library_vibe.dart';
import '../../core/widgets/vibe_face.dart';
import '../cards/flippable_card.dart';
import 'library_vibes_repository.dart';
import 'masked_placeholder.dart';

/// Ouverture d'une vibe **en grand**, révélée ou non, avec bascule de face.
///
/// Demande de Jay au test de la v0.9.44 : « pouvoir ouvrir en grand la vibe
/// floutée et switcher de face, même floutée. Comme dans la bibliothèque du
/// profil un peu. »
///
/// L'intérêt n'est pas anecdotique : avant le reveal, la seule chose qu'on
/// puisse faire d'une vibe est la regarder de loin. Pouvoir la retourner rend
/// l'attente vivante — on devine deux ambiances au lieu d'une.
///
/// Avant 18h30 on retourne les **placeholders** ; après, les vraies faces. Le
/// geste est le même dans les deux cas, et c'est le même widget de
/// retournement que dans la bibliothèque du profil ([FlippableCard]).
class VibeFacesScreen extends ConsumerStatefulWidget {
  const VibeFacesScreen({super.key, required this.vibe, this.frontPlaceholder});

  final LibraryVibe vibe;

  /// Déjà en mémoire dans la tuile d'où l'on vient : évite un rechargement et
  /// une rupture visuelle à l'ouverture.
  final Uint8List? frontPlaceholder;

  @override
  ConsumerState<VibeFacesScreen> createState() => _VibeFacesScreenState();
}

class _VibeFacesScreenState extends ConsumerState<VibeFacesScreen> {
  Uint8List? _front;
  Uint8List? _back;

  /// Faces réelles, chargées seulement si la vibe est révélée.
  ///
  /// [OpenedMedia] et non `File` depuis le 2026-08-13 : une photo arrive en
  /// mémoire, une vidéo se lit par blocs via le lecteur natif. **Aucun clair
  /// sur le disque** — et une face vidéo s'affiche enfin, là où `Image.file`
  /// sur un `.mp4` ne pouvait rien rendre.
  OpenedMedia? _frontMedia;
  OpenedMedia? _backMedia;

  String? _error;

  /// La face posee a l'ecran : celle qui joue avec le son.
  var _showFront = true;

  /// Flou en plein écran. Bien plus élevé que sur une tuile : le rayon est en
  /// pixels logiques, il suit la taille d'affichage.
  static const _sigma = 40.0;

  @override
  void initState() {
    super.initState();
    _front = widget.frontPlaceholder;
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(libraryVibesRepositoryProvider);
    final vibe = widget.vibe;

    if (_front == null) {
      try {
        final bytes = await repo.placeholderBytes(vibe);
        if (mounted) setState(() => _front = bytes);
      } catch (_) {
        // Cadre neutre : mieux qu'un écran vide.
      }
    }
    if (vibe.hasBack) {
      try {
        final bytes = await repo.placeholderBytes(vibe, back: true);
        if (mounted) setState(() => _back = bytes);
      } catch (_) {}
    }

    if (!vibe.revealed) return;

    // Révélée : on remplace les placeholders par les vraies faces.
    try {
      final front = await repo.openRevealed(vibe, isVideo: vibe.frontIsVideo);
      if (mounted) setState(() => _frontMedia = front);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (vibe.hasBack) {
      try {
        final back = await repo.openRevealed(
          vibe,
          isVideo: vibe.backIsVideo,
          back: true,
        );
        if (mounted) setState(() => _backMedia = back);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    // Le clair d'un média HÉRITÉ (format d'avant les blocs) meurt avec l'écran.
    _frontMedia?.dispose();
    _backMedia?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vibe = widget.vibe;
    final revealed = vibe.revealed;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          revealed ? vibe.type.tag : 'Visible à 18h30',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: _error != null
                ? Text(
                    'Impossible d\'ouvrir cette vibe.\n$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  )
                // Une vibe à face unique n'a rien à retourner : on n'installe
                // pas un geste qui ne mènerait nulle part.
                : vibe.hasBack
                ? FlippableCard(
                    onSideChanged: (f) => setState(() => _showFront = f),
                    front: _face(front: true),
                    back: _face(front: false),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: _face(front: true),
                  ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 24, right: 24),
          child: Text(
            vibe.hasBack
                ? (revealed
                      ? 'Swipe pour retourner'
                      : 'Swipe pour retourner — les deux faces restent floutées')
                : (revealed ? '' : 'Tout se découvre à 18h30'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _face({required bool front}) {
    final media = front ? _frontMedia : _backMedia;
    // Face réelle si la vibe est révélée ET que l'ouverture a abouti.
    if (media != null) {
      final isVideo = front
          ? widget.vibe.frontIsVideo
          : widget.vibe.backIsVideo;
      // Une vibe reste une Vibe : même cadre, même couleur de type. C'est
      // l'apparence du contenu, elle ne dépend pas du contexte de diffusion.
      return isVideo
          ? VibeVideoFace(
              media: media,
              type: widget.vibe.type,
              // La face visible est celle qu'on regarde : l'autre reste en
              // pause et muette derrière la carte.
              active: front == _showFront,
            )
          : VibePhotoFace(bytes: media.photoBytes!, type: widget.vibe.type);
    }
    final bytes = front ? _front : _back;
    if (bytes == null) {
      return const ColoredBox(
        color: Color(0xFF1E1B29),
        child: Center(child: CircularProgressIndicator(color: Colors.white24)),
      );
    }
    return MaskedPlaceholder(bytes: bytes, sigma: _sigma);
  }
}
