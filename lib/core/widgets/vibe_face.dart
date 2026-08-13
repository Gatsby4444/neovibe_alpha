import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../crypto/media_open.dart';
import '../models/card.dart';
import '../video/sealed_video_controller.dart';
import '../video/sealed_video_view.dart';

/// L'**apparence** d'une face de Vibe : liseré à la couleur du type (dégradé
/// pour Oneshot et BeReal, or épais pour la One of One), coins arrondis, fond
/// noir, halo coloré.
///
/// Vit dans `core/widgets` depuis le 2026-08-11, et c'est une correction.
/// `CardViewerScreen` mélangeait **deux choses** : les RÈGLES d'une Vibe
/// envoyée (livraisons, budgets de vues, durées, replay) et la PRÉSENTATION
/// d'une Vibe. En écrivant les visionneuses de stories et de publications,
/// j'ai eu raison d'écarter les premières — et tort d'abandonner la seconde
/// avec : les contenus s'affichaient en image nue, sans cadre ni couleur de
/// type. Jay l'a vu immédiatement (« les cards ne s'affichent plus comme
/// avant »).
///
/// **Une Vibe doit ressembler à une Vibe, quel que soit son contexte de
/// diffusion.** L'apparence appartient au contenu ; seules les règles
/// appartiennent au format.
class VibeFaceFrame extends StatelessWidget {
  const VibeFaceFrame({super.key, required this.type, required this.child});

  final CardType type;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final borderWidth = type == CardType.oneOfOne ? 4.0 : 2.5;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.all(borderWidth),
      decoration: BoxDecoration(
        gradient: type.gradient,
        color: type.gradient == null ? type.color : null,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: type.color.withValues(alpha: 0.35), blurRadius: 24),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: ColoredBox(color: Colors.black, child: child),
      ),
    );
  }
}

/// Face photo d'une Vibe, dans son cadre.
///
/// Elle reçoit des **octets en mémoire**, pas un fichier : depuis le format
/// par blocs, une photo déchiffrée ne touche jamais le disque.
/// Une face **pas encore arrivée**, au cadre de son type.
///
/// ### Pourquoi ce widget existe — et pourquoi il n'est pas cosmétique
///
/// Les deux visionneuses choisissaient leur structure d'après l'état du verso :
/// `TiltableCard` tant qu'il chargeait, `FlippableCard` une fois arrivé. À la
/// même position de l'arbre, le widget changeait donc de **type** — et Flutter
/// n'apparie jamais deux widgets de types différents : il démonte tout le
/// sous-arbre et en inflate un neuf. **Le lecteur vidéo du recto était détruit
/// et reconstruit au milieu de la lecture.**
///
/// Relevé chez Jay le 2026-08-13 (v0.9.67) : la vidéo du recto redémarrait, un
/// second décodeur était instancié, et la trace de mesure — toujours ouverte —
/// se voyait écraser son `· attente avant natif` par le temps de
/// téléchargement du verso : **2 873 ms, 3 316 ms**, et jusqu'à **550 545 ms**
/// sur une session où le téléphone avait été posé.
///
/// La configuration qui le déclenche est banale : un recto **vidéo** (qui ne
/// télécharge rien, il se lit par blocs) et un verso **photo** (téléchargé en
/// entier). Le recto gagne toujours la course.
///
/// La structure ne dépend donc plus que de [Card.hasBack], constant pendant
/// toute la vie de l'écran. Le verso qui charge occupe sa place au lieu de la
/// créer en arrivant.
class VibeFaceLoading extends StatelessWidget {
  const VibeFaceLoading({super.key, required this.type});

  final CardType type;

  @override
  Widget build(BuildContext context) => VibeFaceFrame(
    type: type,
    child: const AspectRatio(
      aspectRatio: 3 / 4,
      child: Center(child: CircularProgressIndicator(color: Colors.white24)),
    ),
  );
}

class VibePhotoFace extends StatelessWidget {
  const VibePhotoFace({super.key, required this.bytes, required this.type});

  final Uint8List bytes;
  final CardType type;

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: type,
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const AspectRatio(
          aspectRatio: 3 / 4,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image, color: Colors.white38, size: 40),
                SizedBox(height: 8),
                Text(
                  'Image indisponible',
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// L'état d'échec d'une face vidéo, commun aux deux lecteurs.
///
/// Il existe parce qu'un échec silencieux est **pire qu'une erreur** : Jay a
/// signalé une vidéo qui « charge indéfiniment » (2026-08-12) alors que le
/// lecteur avait échoué en une seconde — l'échec n'était simplement affiché
/// nulle part. Le message technique est accessible d'un appui, pour que le
/// prochain diagnostic parte d'une cause et non d'un symptôme.
class VideoFaceError extends StatelessWidget {
  const VideoFaceError({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white38, size: 40),
            const SizedBox(height: 10),
            const Text(
              'Vidéo illisible',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Détail technique'),
                  content: SingleChildScrollView(child: Text('$error')),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Fermer'),
                    ),
                  ],
                ),
              ),
              child: const Text('Détail'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Face vidéo d'une Vibe **sans limite de lecture** : story, publication.
///
/// Elle boucle, sa barre est librement déplaçable, et elle ne se déclare
/// jamais « terminée » — il n'y a aucun budget à consommer. Le chat, lui,
/// garde sa propre face vidéo dans `CardViewerScreen` : elle doit compter les
/// visionnages, synchroniser les deux faces d'un Oneshot filmé et verrouiller
/// la barre selon le choix de l'émetteur. **Seul le cadre est commun** — et
/// c'est exactement la bonne frontière.
class VibeVideoFace extends StatefulWidget {
  const VibeVideoFace({
    super.key,
    required this.media,
    required this.type,
    required this.active,
  });

  /// Le média ouvert : une vidéo scellée que le lecteur natif lit bloc par
  /// bloc, ou — pour un contenu antérieur au format par blocs — un fichier
  /// temporaire en clair. [OpenedMedia] est seul à connaître la différence.
  final OpenedMedia media;
  final CardType type;

  /// La face est posée à l'écran : la vidéo joue avec le son. Sinon elle est
  /// en pause et muette.
  final bool active;

  @override
  State<VibeVideoFace> createState() => _VibeVideoFaceState();
}

class _VibeVideoFaceState extends State<VibeVideoFace> {
  // Le lecteur NATIF : il réclame des intervalles et les déchiffre lui-même,
  // sur ses propres fils. Rien n'est écrit en clair sur le disque, et l'isolate
  // qui dessine ne transporte plus un octet de vidéo.
  late final SealedVideoController _controller = widget.media.videoController();

  /// L'échec d'ouverture, s'il y en a un. Tant qu'il était avalé, une vidéo
  /// impossible à lire tournait indéfiniment sur son indicateur de chargement
  /// (panne du 2026-08-12). **Les trois états doivent se distinguer au premier
  /// coup d'œil** : chargement, lecture, échec.
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          _controller.setLooping(true);
          _controller.setVolume(widget.active ? 1 : 0);
          if (widget.active) _controller.play();
          setState(() {});
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  @override
  void didUpdateWidget(covariant VibeVideoFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_controller.value.isInitialized) return;
    _controller.setVolume(widget.active ? 1 : 0);
    widget.active ? _controller.play() : _controller.pause();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: widget.type,
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: _error != null
            ? VideoFaceError(error: _error!)
            : !_controller.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: _controller.value.size.width,
                      height: _controller.value.size.height,
                      child: SealedVideoView(_controller),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SealedVideoProgressBar(
                      controller: _controller,
                      allowScrubbing: true,
                      playedColor: widget.type.color,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
