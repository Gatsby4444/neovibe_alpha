import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../crypto/media_open.dart';
import '../models/card.dart';
import '../video/sealed_video_controller.dart';
import '../video/sealed_video_view.dart';
import '../video/video_watchdog.dart';

/// Le format d'une face de Vibe : portrait 9:16, celui de la capture
/// (`card_capture_screen.dart`, `targetRatio`).
///
/// ⚠️ **Toute face l'impose, dans tous ses états** — en attente, photo,
/// vidéo, erreur. Constaté chez Jay le 2026-09-15 (v0.9.189) : la face photo
/// prenait la hauteur de l'image *une fois décodée*, donc zéro avant. Dans
/// une liste, retourner une Card inflatait un verso neuf : la cellule
/// s'écrasait une image de temps, la liste remontait pour combler, la Card
/// suivante passait sous le doigt (« un flash d'une autre card »), et tout en
/// bas la position ne revenait pas (« ça remonte d'une card »). Seul, centré
/// dans un visionneur, ça ne se voyait pas. La hauteur d'une face ne dépend
/// plus jamais de ce qui est chargé.
const kVibeFaceRatio = 9 / 16;

/// **Le format d'une Vibe quand elle n'est pas en plein écran** : 4:5.
///
/// Règle reprise d'Instagram par Jay le 2026-09-17 : un Reel est **publié**
/// en 9:16, mais dès qu'il défile dans le fil classique il est **recadré en
/// 4:5**. Nos Vibes sont nos Reels : elles gardent leur 9:16 (c'est le
/// format du contenu, il ne bouge pas), et ce sont le **fil** et la **grille
/// du profil** qui en montrent un 4:5.
///
/// ⚠️ Recadrer, c'est **montrer moins**, pas montrer plus petit : à un
/// format qui n'est pas le sien, une face se coupe (`BoxFit.cover`) au lieu
/// de se poser dans des bandes noires. Voir [fitForRatio].
const kVibeFeedRatio = 4 / 5;

/// Comment une face remplit son cadre : **à son format natif rien n'est
/// coupé** ; à tout autre format, on recadre.
BoxFit fitForRatio(double ratio) =>
    ratio == kVibeFaceRatio ? BoxFit.contain : BoxFit.cover;

/// **Comment une Vibe s'affiche, selon l'endroit où on la regarde.**
///
/// Le format et la marge du cadre voyageaient jusqu'ici en paramètres
/// séparés, de widget en widget — deux réglages d'une même chose, qu'on
/// pouvait changer l'un sans l'autre. Ils sont ici, ensemble, avec les trois
/// seules combinaisons qui existent :
///
/// | | format | marge | où |
/// |---|---|---|---|
/// | [card] | 9:16 | 16 | partout ailleurs (story, Vibe reçue, Enregistrements) |
/// | [feed] | 4:5 | 16 | le fil et la grille — **recadrée**, comme un Reel |
/// | [full] | 9:16 | 8 | le plein écran : la carte au plus près des bords |
class VibeDisplay {
  const VibeDisplay({required this.ratio, required this.margin});

  /// La Vibe à son format, dans un écran qui n'est pas à elle.
  static const card = VibeDisplay(ratio: kVibeFaceRatio, margin: 16);

  /// Recadrée pour un fil ou une grille (voir [kVibeFeedRatio]).
  static const feed = VibeDisplay(ratio: kVibeFeedRatio, margin: 16);

  /// Le plein écran. La marge y est **plus courte** : elle est tout ce qui
  /// sépare deux Vibes quand on passe de l'une à l'autre, et Jay la trouvait
  /// « un peu grande » (2026-09-17). Deux Vibes ne sont jamais visibles
  /// ensemble pour autant : une page fait toujours un écran entier.
  static const full = VibeDisplay(ratio: kVibeFaceRatio, margin: 8);

  final double ratio;
  final double margin;

  /// Ce que le cadre ajoute à l'image, en largeur comme en hauteur.
  double chrome(CardType type) => 2 * (margin + VibeFaceFrame.liseret(type));

  /// Recadrer, c'est montrer moins (voir [fitForRatio]).
  BoxFit get fit => fitForRatio(ratio);
}

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
  const VibeFaceFrame({
    super.key,
    required this.type,
    required this.child,
    this.overlay,
    this.display = VibeDisplay.card,
  });

  final CardType type;
  final Widget child;

  /// **Ce qui se pose SUR la face, dans le cadre** — l'identité, les actions,
  /// la légende en plein écran (`VibeCardChrome`). Il est ici, et pas
  /// par-dessus la carte, pour une raison précise : *dans* le cadre, il
  /// appartient à la carte, donc il s'incline et se retourne avec elle
  /// (demande de Jay, 2026-09-16 : *« incorporer les boutons dans la card à
  /// droite mais qu'ils bougent avec la card »*). Posé au-dessus, il resterait
  /// immobile pendant que la carte tourne.
  ///
  /// Il est **coupé aux coins arrondis** comme l'image, et il ne couvre que ce
  /// qu'il dessine : le reste laisse passer le doigt (la barre de lecture
  /// d'une vidéo reste attrapable).
  final Widget? overlay;

  /// Format et marge — voir [VibeDisplay].
  final VibeDisplay display;

  /// L'épaisseur du liseré, qui dépend du type.
  static double liseret(CardType type) => type == CardType.oneOfOne ? 4.0 : 2.5;

  /// **Ce que le cadre ajoute à l'image**, en largeur comme en hauteur (les
  /// deux marges et les deux liserés). Une seule définition : celle qui
  /// dessine le cadre, et celle dont se sert une mise en page qui veut poser
  /// une carte à une taille voulue. La deviner, c'est deux chiffres qui se
  /// désaccordent au premier changement de style.
  static double chrome(
    CardType type, [
    VibeDisplay display = VibeDisplay.card,
  ]) => display.chrome(type);

  @override
  Widget build(BuildContext context) {
    final borderWidth = liseret(type);
    return Container(
      margin: EdgeInsets.all(display.margin),
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
        child: ColoredBox(
          color: Colors.black,
          child: overlay == null
              ? child
              // ⚠️ `child` est le SEUL enfant non positionné : c'est lui qui
              // donne sa taille à la pile (le calque ne doit rien décider de
              // la taille de la face).
              : Stack(
                  children: [
                    child,
                    Positioned.fill(child: overlay!),
                  ],
                ),
        ),
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
  const VibeFaceLoading({
    super.key,
    required this.type,
    this.overlay,
    this.display = VibeDisplay.card,
  });

  final CardType type;
  final Widget? overlay;

  /// Format et marge (voir [VibeDisplay]). **Ils ne dépendent jamais de ce
  /// qui est chargé** (voir [kVibeFaceRatio]).
  final VibeDisplay display;

  @override
  Widget build(BuildContext context) => VibeFaceFrame(
    type: type,
    overlay: overlay,
    display: display,
    child: AspectRatio(
      aspectRatio: display.ratio,
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white24),
      ),
    ),
  );
}

class VibePhotoFace extends StatelessWidget {
  const VibePhotoFace({
    super.key,
    required this.bytes,
    required this.type,
    this.overlay,
    this.display = VibeDisplay.card,
  });

  final Uint8List bytes;
  final CardType type;
  final Widget? overlay;

  /// Voir [VibeFaceLoading.display].
  final VibeDisplay display;

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: type,
      overlay: overlay,
      display: display,
      child: AspectRatio(
        aspectRatio: display.ratio,
        child: Image.memory(
          bytes,
          fit: display.fit,
          errorBuilder: (context, error, stack) => const Center(
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
    this.overlay,
    this.display = VibeDisplay.card,
  });

  /// Le média ouvert : une vidéo scellée que le lecteur natif lit bloc par
  /// bloc, ou — pour un contenu antérieur au format par blocs — un fichier
  /// temporaire en clair. [OpenedMedia] est seul à connaître la différence.
  final OpenedMedia media;
  final CardType type;

  /// La face est posée à l'écran : la vidéo joue avec le son. Sinon elle est
  /// en pause et muette.
  final bool active;

  /// Voir [VibeFaceFrame.overlay].
  final Widget? overlay;

  /// Voir [VibeFaceLoading.display]. La vidéo remplit déjà son cadre en
  /// `cover` : elle se recadre sans rien changer d'autre.
  final VibeDisplay display;

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
    // ⚠️ **On écoute le lecteur, pas seulement son ouverture.** Un décodeur
    // peut mourir en cours de route — le son continue, l'image devient noire
    // (Jay, 2026-09-17). Sans cette écoute, l'échec n'arrive nulle part.
    _controller.addListener(_onValeur);
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

  void _onValeur() {
    final e = _controller.value.error;
    if (e != null && _error == null && mounted) setState(() => _error = e);
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
    _controller.removeListener(_onValeur);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: widget.type,
      overlay: widget.overlay,
      display: widget.display,
      child: AspectRatio(
        aspectRatio: widget.display.ratio,
        child: _error != null
            ? VideoFaceError(error: _error!)
            : !_controller.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                fit: StackFit.expand,
                children: [
                  VideoWatchdog(
                    controller: _controller,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: _controller.value.size.width,
                        height: _controller.value.size.height,
                        child: SealedVideoView(_controller),
                      ),
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
