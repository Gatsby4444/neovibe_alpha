import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/crypto/media_seal.dart';

import '../../core/models/card.dart';
import '../../core/widgets/card_type_badge.dart';
import '../../core/widgets/save_button.dart';
import '../../core/widgets/vibe_face.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import 'card_media_cache.dart';
import 'cards_repository.dart';
import 'flippable_card.dart';

/// Étapes d'affichage d'une Card.
enum _Phase { loading, error, viewing, exhausted, destroyed }

/// Visionnage d'une Card.
/// - En chat (destinataire) : l'ouverture consomme immédiatement une vue
///   (1 vue = 1 ouverture, consigne Jay 2026-07-12). Chaque FACE a ensuite
///   son budget : une face photo s'écoule (jauge) uniquement pendant qu'elle
///   est affichée ; une face vidéo se lit en entier (barre de lecture,
///   contrôlable seulement si le créateur l'a permis). Retourner la carte
///   coupe court à la face qu'on quitte ; la card se ferme quand toutes les
///   faces sont épuisées.
/// - Card à face unique (verso passé) : pas de retournement, seulement le jeu
///   d'angle.
/// - En bibliothèque ou pour l'émetteur : lecture illimitée, sans budgets.
class CardViewerScreen extends ConsumerStatefulWidget {
  const CardViewerScreen({
    super.key,
    required this.card,
    this.fromLibrary = false,
    this.chromeless = false,
  });

  final CardModel card;

  /// Ouvert depuis une bibliothèque : visionnage illimité (consigne Jay).
  final bool fromLibrary;

  /// Sans habillage : ni AppBar, ni bandeau d'aide, fond transparent. L'écran
  /// appelant fournit sa propre surcouche — c'est le cas de la visionneuse de
  /// stories, dont l'en-tête tombait sinon PAR-DESSUS l'AppBar de la Card
  /// (défaut relevé au test de la v0.9.40).
  final bool chromeless;

  @override
  ConsumerState<CardViewerScreen> createState() => _CardViewerScreenState();
}

class _CardViewerScreenState extends ConsumerState<CardViewerScreen> {
  var _phase = _Phase.loading;

  /// Face actuellement montrée pendant le geste (pour le texte d'aide).
  var _showFront = true;

  /// Face sur laquelle la carte est POSÉE (les budgets suivent celle-ci).
  var _settledFront = true;

  /// Faces servies depuis le cache local (préchargées ENSEMBLE : le
  /// retournement n'attend plus jamais le réseau — consigne Jay 2026-07-13).
  File? _frontFile;
  File? _backFile;

  /// Faces DÉCHIFFRÉES, dans le répertoire temporaire. Nulles pour une Vibe
  /// d'avant le chiffrement (2026-08-10), qui s'affiche directement.
  File? _clearFront;
  File? _clearBack;

  /// Ce que l'affichage doit lire : le clair s'il existe, sinon le fichier tel
  /// quel (Vibes antérieures au chiffrement).
  File? get _shownFront => _clearFront ?? _frontFile;
  File? get _shownBack => _clearBack ?? _backFile;
  String _error = '';
  CardDelivery? _delivery;

  /// Budgets par face (destinataire en chat uniquement).
  var _frontDone = false;
  var _backDone = false;
  var _sessionEnded = false;

  /// Jauge de lecture de la face photo affichée : 1 → 0.
  Timer? _gaugeTimer;
  double _gauge = 1.0;
  int _elapsedMs = 0;

  /// Capturé à l'initialisation : `ref` est interdit dans `dispose()` —
  /// c'était la source des « Using "ref" when a widget is about to or has been
  /// unmounted » du journal, à chaque fermeture de card.
  late final String? _me = ref.read(currentUserIdProvider);

  bool get _isRecipient => _me != null && _me != widget.card.ownerId;

  /// Les limites (vues, budgets par face) ne s'appliquent qu'au destinataire
  /// en chat.
  bool get _limitsApply => _isRecipient && !widget.fromLibrary;

  bool _faceIsVideo(bool front) =>
      front ? widget.card.frontIsVideo : widget.card.backIsVideo;

  /// Card dont les deux faces sont filmées (Oneshot vidéo) : les deux lecteurs
  /// tournent en parallèle, seul celui de la face regardée a le son.
  bool get _bothFacesVideo =>
      widget.card.frontIsVideo && widget.card.backIsVideo;

  /// Dernière position de lecture de la face regardée. Champ simple, JAMAIS
  /// dans un `setState` : il est mis à jour à chaque image et ne sert qu'au
  /// moment du retournement (rattrapage de dérive entre les deux lecteurs).
  Duration _videoPosition = Duration.zero;

  bool _faceDone(bool front) => front ? _frontDone : _backDone;

  /// Dépendances capturées à l'initialisation : `dispose()` en a besoin, et
  /// `ref` n'y est plus utilisable (le widget est démonté).
  late final _cards = ref.read(cardsRepositoryProvider);
  late final _cache = ref.read(cardMediaCacheProvider);
  late final _quotaMb = ref.read(ownCardsQuotaMbProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Récupère les DEUX faces via le cache local : mes cards depuis `own/`
  /// (zéro requête si déjà locales), celles des autres depuis `others/`
  /// avec leur politique de rétention. Téléchargements en parallèle.
  Future<void> _fetchFaces() async {
    final repo = _cards;
    final cache = _cache;
    final card = widget.card;
    final isOwner = !_isRecipient;
    Future<File> face(bool front) {
      final path = front ? card.frontPath : card.backPath!;
      if (isOwner) {
        return cache.ownFace(
          card,
          front: front,
          signedUrl: () => repo.imageUrl(path),
          quotaMb: _quotaMb,
        );
      }
      return cache.othersFace(
        card,
        front: front,
        policy: _limitsApply ? CardCachePolicy.chat : CardCachePolicy.browse,
        signedUrl: () => repo.imageUrl(path),
      );
    }

    final faces = await Future.wait([
      face(true),
      if (card.backPath != null) face(false),
    ]);
    _frontFile = faces[0];
    _backFile = faces.length > 1 ? faces[1] : null;
  }

  /// Déchiffre les faces d'une Vibe scellée.
  ///
  /// ⚠️ **C'est cet appel qui consomme une vue**, pas un décompte séparé :
  /// `open_card_media` vérifie, décrémente et rend la clé dans une seule
  /// transaction serveur. Un client modifié ne peut plus sauter le décompte,
  /// puisque c'est lui qui délivre de quoi lire (décision de Jay 2026-08-10 :
  /// la limite de vues est une garantie, pas une convention).
  ///
  /// Les fichiers en cache restent chiffrés ; le clair vit dans le répertoire
  /// temporaire et est supprimé en quittant l'écran ([dispose]).
  Future<void> _unsealFaces() async {
    final key = await _cards.openMedia(widget.card.id);
    final temp = await getTemporaryDirectory();

    Future<File> open(File sealed, bool front) => MediaSeal.unsealToFile(
      sealed,
      key,
      File('${temp.path}/clear_${widget.card.id}_${front ? 'f' : 'b'}'),
    );

    _clearFront = await open(_frontFile!, true);
    if (_backFile != null) _clearBack = await open(_backFile!, false);
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = '';
    });
    final repo = _cards;
    try {
      if (!_limitsApply) {
        await _fetchFaces();
        if (widget.card.encrypted) await _unsealFaces();
        if (!mounted) return;
        setState(() => _phase = _Phase.viewing);
        return;
      }

      // Destinataire : l'état de la livraison d'abord — inutile de
      // télécharger les faces d'une card épuisée ou détruite.
      _delivery = await repo.myDelivery(widget.card.id);
      if (!mounted) return;
      if (_delivery == null) {
        // Pas de livraison pour moi (ne devrait pas arriver en chat)
        await _fetchFaces();
        if (widget.card.encrypted) await _unsealFaces();
        if (!mounted) return;
        setState(() => _phase = _Phase.viewing);
        return;
      }
      if (_delivery!.destroyedAt != null) {
        await _cache.purgeCard(widget.card.id);
        if (!mounted) return;
        setState(() => _phase = _Phase.destroyed);
        return;
      }
      final remaining = _delivery!.remainingViews(widget.card);
      if (remaining != null && remaining <= 0) {
        await _cache.purgeCard(widget.card.id);
        if (!mounted) return;
        setState(() => _phase = _Phase.exhausted);
        return;
      }

      await _fetchFaces();
      if (!mounted) return;

      // Consomme une vue (1 vue = 1 ouverture) et démarre le budget du recto.
      // Vibe chiffrée : le décompte EST la remise de la clé, `markViewed` n'a
      // plus lieu d'être — l'appeler consommerait deux vues.
      if (widget.card.encrypted) {
        await _unsealFaces();
      } else {
        await repo.markViewed(_delivery!.id);
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.viewing);
      _startFaceBudget(true);
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      if (text.contains('Plus de visionnages')) {
        setState(() => _phase = _Phase.exhausted);
      } else if (text.contains('détruite') || text.contains('une fois')) {
        setState(() => _phase = _Phase.destroyed);
      } else {
        setState(() {
          _phase = _Phase.error;
          _error = text;
        });
      }
    }
  }

  /// Démarre le budget de la face [front] : jauge pour une photo (si le
  /// créateur a limité la durée), rien pour une vidéo (sa fin de lecture
  /// fait foi) ni en lecture illimitée.
  void _startFaceBudget(bool front) {
    _gaugeTimer?.cancel();
    if (!_limitsApply || _faceIsVideo(front) || _faceDone(front)) return;
    final duration = widget.card.viewDurationSeconds;
    if (duration == null) return; // lecture illimitée : pas de jauge
    final totalMs = duration * 1000;
    _elapsedMs = 0;
    _gauge = 1.0;
    _gaugeTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      _elapsedMs += 50;
      setState(() => _gauge = 1.0 - (_elapsedMs / totalMs).clamp(0.0, 1.0));
      if (_elapsedMs >= totalMs) {
        _gaugeTimer?.cancel();
        _markFaceDone(front);
      }
    });
  }

  /// Épuise une face (temps écoulé, vidéo terminée ou carte retournée =
  /// couper court). Ferme la session quand toutes les faces sont épuisées.
  void _markFaceDone(bool front) {
    if (!_limitsApply || _sessionEnded || _faceDone(front)) return;
    setState(() => front ? _frontDone = true : _backDone = true);
    final otherDone = front
        ? (_backDone || widget.card.backPath == null)
        : _frontDone;
    if (otherDone) _endSession();
  }

  /// Retournement POSÉ (signal fiable de FlippableCard) : la face quittée
  /// est coupée court ; si la face d'arrivée est déjà épuisée, la session
  /// se termine, sinon son budget démarre.
  void _onSideSettled(bool front) {
    if (front == _settledFront) return; // reposée sur la même face
    final left = _settledFront;
    setState(() => _settledFront = front);
    if (!_limitsApply || _sessionEnded) return;
    _markFaceDone(left);
    if (_sessionEnded) return;
    if (_faceDone(front)) {
      _endSession();
    } else {
      _startFaceBudget(front);
    }
  }

  /// Toutes les faces sont épuisées : état des vues restantes (replay) ou
  /// fermeture.
  Future<void> _endSession() async {
    if (_sessionEnded) return;
    _sessionEnded = true;
    _gaugeTimer?.cancel();
    _delivery = await ref
        .read(cardsRepositoryProvider)
        .myDelivery(widget.card.id);
    if (!mounted) return;
    final remaining = _delivery?.remainingViews(widget.card);
    if (remaining != null && remaining <= 0) {
      // Plus aucune vue : rien ne doit rester sur l'appareil.
      await _cache.purgeCard(widget.card.id);
      if (!mounted) return;
      setState(() => _phase = _Phase.exhausted);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _requestReplay() async {
    try {
      await _cards.requestReplay(_delivery!.id);
      _delivery = await ref
          .read(cardsRepositoryProvider)
          .myDelivery(widget.card.id);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  @override
  void dispose() {
    _gaugeTimer?.cancel();
    // Le clair ne survit pas à l'écran : le cache garde le scellé, la copie
    // lisible disparaît avec la visionneuse. C'est ce qui rend le décompte
    // utile — sans cela, le fichier déchiffré resterait consultable hors
    // contrôle du serveur.
    for (final file in [_clearFront, _clearBack]) {
      if (file == null) continue;
      file.delete().catchError((_) => file);
    }
    super.dispose();
  }

  /// Construit la face [front] : photo, vidéo ou écran « face terminée ».
  Widget _buildFace(bool front) {
    final type = widget.card.type;
    if (_limitsApply && _faceDone(front)) {
      return _DeadFace(
        type: type,
        bothDone: front
            ? (_backDone || widget.card.backPath == null)
            : _frontDone,
      );
    }
    final file = front ? _shownFront! : _shownBack!;
    if (_faceIsVideo(front)) {
      return _VideoFace(
        file: file,
        type: type,
        // La vidéo ne joue que lorsque sa face est posée à l'écran
        active: _phase == _Phase.viewing && _settledFront == front,
        // Oneshot filmé : les deux faces sont le même instant vu de deux
        // côtés. Elles tournent donc ENSEMBLE (la cachée en silence) et le
        // retournement ne fait que déplacer le son — sinon la face d'arrivée
        // repartait de zéro (retour de Jay, v0.9.20).
        playsWhenHidden: _bothFacesVideo && _phase == _Phase.viewing,
        syncTo: _bothFacesVideo ? _videoPosition : null,
        onPosition: _bothFacesVideo ? (p) => _videoPosition = p : null,
        // Barre intouchable pour le destinataire sauf accord du créateur ;
        // toujours libre pour l'émetteur et en bibliothèque.
        allowScrub: !_limitsApply || widget.card.scrubbable,
        // En lecture illimitée la vidéo boucle ; en chat elle compte une fois
        loop: !_limitsApply,
        onCompleted: _limitsApply ? () => _markFaceDone(front) : null,
      );
    }
    return VibePhotoFace(file: file, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.card.type;
    final me = ref.watch(currentUserIdProvider);
    // Enregistrable : ses propres cards (1/1 exclue — le créateur la rouvre
    // depuis le chat à la place), ou une card reçue marquée sauvegardable par
    // son créateur.
    final isOwner = widget.card.ownerId == me;
    final canSave = isOwner
        ? type != CardType.oneOfOne
        : (widget.card.saveable && type.canBeSaveable);

    // Jauge visible : face photo posée, à durée limitée, encore vivante
    final showGauge =
        _phase == _Phase.viewing &&
        _limitsApply &&
        widget.card.viewDurationSeconds != null &&
        !_faceIsVideo(_settledFront) &&
        !_faceDone(_settledFront);

    return Scaffold(
      backgroundColor: widget.chromeless ? Colors.transparent : Colors.black,
      appBar: widget.chromeless
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              title: CardTypeBadge(type: type),
              actions: [
                // Enregistrer : une copie EN CLAIR sur l'appareil, faite
                // à partir des faces déjà déchiffrées à l'écran. Depuis
                // l'étape 5, plus aucune ligne serveur — c'est ce qui rend la
                // sauvegarde indépendante de son auteur.
                if (_phase == _Phase.viewing)
                  SaveButton(
                    contentId: widget.card.id,
                    cardType: type,
                    canSave: canSave,
                    front: _shownFront,
                    back: _shownBack,
                    frontIsVideo: widget.card.frontIsVideo,
                    backIsVideo: widget.card.backIsVideo,
                    mine: isOwner,
                  ),
              ],
              bottom: showGauge
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(6),
                      // Jauge de lecture : s'écoule de gauche à droite (consigne Jay)
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: _gauge,
                          child: Container(height: 5, color: type.color),
                        ),
                      ),
                    )
                  : null,
            ),
      body: switch (_phase) {
        _Phase.loading => const _LoadingState(),
        _Phase.error => _ErrorState(detail: _error, onRetry: _load),
        _Phase.destroyed => _EndState(
          icon: Icons.lock_outline,
          color: type.color,
          message: 'Cette Vibe a été détruite.',
        ),
        _Phase.exhausted => _ExhaustedState(
          card: widget.card,
          delivery: _delivery,
          onReplayRequested: _requestReplay,
        ),
        // Face unique (verso passé) : non retournable, le jeu d'angle reste
        _Phase.viewing when _shownBack == null => Center(
          child: TiltableCard(child: _buildFace(true)),
        ),
        _Phase.viewing => Center(
          child: FlippableCard(
            invertDrag: ref.watch(flipDirectionInvertedProvider),
            onSideChanged: (front) => setState(() => _showFront = front),
            onSideSettled: _onSideSettled,
            front: _buildFace(true),
            back: _buildFace(false),
          ),
        ),
      },
      bottomNavigationBar: _phase == _Phase.viewing && !widget.chromeless
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _shownBack == null
                      ? 'Face unique — fais glisser pour incliner la carte'
                      : _limitsApply
                      ? (_showFront
                            ? 'Recto — retourner coupe court à cette face'
                            : 'Verso — retourner coupe court à cette face')
                      : (_showFront
                            ? 'Recto — fais glisser pour retourner la carte'
                            : 'Verso — fais glisser pour revenir au recto'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
            )
          : null,
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 44,
            width: 44,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 16),
          Text(
            'Chargement de la Vibe…',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.detail, required this.onRetry});
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            const Text(
              'Impossible de charger la Vibe.\nVérifie ta connexion.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _EndState extends StatelessWidget {
  const _EndState({
    required this.icon,
    required this.color,
    required this.message,
  });
  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: color),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// Plus de vues disponibles : proposer la demande de replay
/// (accordée ou non par l'émetteur — jamais automatique).
class _ExhaustedState extends StatelessWidget {
  const _ExhaustedState({
    required this.card,
    required this.delivery,
    required this.onReplayRequested,
  });
  final CardModel card;
  final CardDelivery? delivery;
  final VoidCallback onReplayRequested;

  @override
  Widget build(BuildContext context) {
    final requested = delivery?.replayRequestedAt != null;
    final granted = delivery?.replayGrantedAt != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off, size: 56, color: card.type.color),
            const SizedBox(height: 16),
            const Text(
              'Tu as utilisé tous tes visionnages pour cette Vibe.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (granted)
              const Text(
                'Replay déjà utilisé.',
                style: TextStyle(color: Colors.white54),
              )
            else if (requested)
              const Text(
                'Replay demandé — en attente de l\'accord de l\'expéditeur.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              )
            else
              FilledButton.tonal(
                onPressed: onReplayRequested,
                child: const Text('Demander un replay'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Face vidéo : lecture avec son, barre de progression toujours visible —
/// contrôlable uniquement si le créateur l'a permis (consigne Jay).
class _VideoFace extends StatefulWidget {
  const _VideoFace({
    required this.file,
    required this.type,
    required this.active,
    required this.allowScrub,
    required this.loop,
    this.onCompleted,
    this.playsWhenHidden = false,
    this.syncTo,
    this.onPosition,
  });
  final File file;
  final CardType type;

  /// Oneshot filmé : la face cachée continue de tourner (en silence) pour que
  /// le retournement tombe sur la suite de l'action et non sur un redémarrage.
  final bool playsWhenHidden;

  /// Position que l'autre face vient de quitter : sert à rattraper une dérive
  /// au retournement.
  final Duration? syncTo;

  /// Remontée de la position de lecture pendant que cette face est regardée.
  final ValueChanged<Duration>? onPosition;

  /// La face est posée à l'écran : la vidéo joue ; sinon elle est en pause.
  final bool active;
  final bool allowScrub;
  final bool loop;
  final VoidCallback? onCompleted;

  @override
  State<_VideoFace> createState() => _VideoFaceState();
}

class _VideoFaceState extends State<_VideoFace> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    widget.file,
  );
  var _completedFired = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTick);
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller.setLooping(widget.loop);
      // Face cachée d'un Oneshot filmé : elle joue quand même, en silence. Les
      // deux faces sont le MÊME instant vu de deux côtés — le retournement doit
      // donc tomber sur la suite, pas sur un redémarrage (consigne Jay).
      _controller.setVolume(widget.active ? 1 : 0);
      if (widget.active || widget.playsWhenHidden) _controller.play();
      setState(() {});
    });
  }

  void _onTick() {
    if (!mounted) return;
    final value = _controller.value;
    // Seule la face REGARDÉE consomme son budget de vue : la face cachée avance
    // en silence et ne doit pas se déclarer terminée toute seule.
    if (widget.active &&
        !widget.loop &&
        !_completedFired &&
        value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration) {
      _completedFired = true;
      widget.onCompleted?.call();
    }
    if (widget.active) widget.onPosition?.call(value.position);
    setState(() {}); // rafraîchit la barre de progression
  }

  @override
  void didUpdateWidget(covariant _VideoFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active || !_controller.value.isInitialized) {
      return;
    }
    if (!widget.playsWhenHidden) {
      widget.active ? _controller.play() : _controller.pause();
      return;
    }
    // Les deux faces tournent en parallèle : on ne fait que déplacer le son.
    _controller.setVolume(widget.active ? 1 : 0);
    if (!widget.active) return;
    // Cette face vient d'arriver à l'écran. Les deux lecteurs ont démarré à
    // quelques dizaines de ms d'écart et peuvent avoir dérivé : on se recale
    // sur la position que l'autre face vient de quitter, mais seulement si
    // l'écart s'entend (un seek systématique ferait un à-coup à chaque
    // retournement).
    final target = widget.syncTo;
    if (target != null) {
      final drift = (_controller.value.position - target).inMilliseconds.abs();
      if (drift > 150) _controller.seekTo(target);
    }
    if (!_controller.value.isPlaying) _controller.play();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: widget.type,
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: !_controller.value.isInitialized
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
                      child: VideoPlayer(_controller),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: VideoProgressIndicator(
                      _controller,
                      allowScrubbing: widget.allowScrub,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      colors: VideoProgressColors(
                        playedColor: widget.type.color,
                        backgroundColor: Colors.white24,
                        bufferedColor: Colors.white38,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Face épuisée (temps écoulé, vidéo terminée ou coupée court) alors que
/// l'autre face reste disponible.
class _DeadFace extends StatelessWidget {
  const _DeadFace({required this.type, required this.bothDone});
  final CardType type;
  final bool bothDone;

  @override
  Widget build(BuildContext context) {
    return VibeFaceFrame(
      type: type,
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timer_off, size: 48, color: Colors.white38),
              const SizedBox(height: 12),
              Text(
                bothDone
                    ? 'Face terminée.'
                    : 'Face terminée — retourne la carte.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
