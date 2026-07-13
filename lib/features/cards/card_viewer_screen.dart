import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/models/card.dart';
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
/// - Hot : une seule vue, puis destruction — le container reste bloqué.
/// - En bibliothèque ou pour l'émetteur : lecture illimitée, sans budgets.
class CardViewerScreen extends ConsumerStatefulWidget {
  const CardViewerScreen({
    super.key,
    required this.card,
    this.fromLibrary = false,
  });

  final CardModel card;

  /// Ouvert depuis une bibliothèque : visionnage illimité (consigne Jay).
  final bool fromLibrary;

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
  var _hotFinished = false;

  bool get _isRecipient {
    final me = ref.read(currentUserIdProvider);
    return me != null && me != widget.card.ownerId;
  }

  /// Les limites (vues, budgets par face) ne s'appliquent qu'au destinataire
  /// en chat.
  bool get _limitsApply => _isRecipient && !widget.fromLibrary;

  bool _faceIsVideo(bool front) =>
      front ? widget.card.frontIsVideo : widget.card.backIsVideo;

  bool _faceDone(bool front) => front ? _frontDone : _backDone;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Récupère les DEUX faces via le cache local : mes cards depuis `own/`
  /// (zéro requête si déjà locales), celles des autres depuis `others/`
  /// avec leur politique de rétention. Téléchargements en parallèle.
  Future<void> _fetchFaces() async {
    final repo = ref.read(cardsRepositoryProvider);
    final cache = ref.read(cardMediaCacheProvider);
    final card = widget.card;
    final isOwner = !_isRecipient;
    Future<File> face(bool front) {
      final path = front ? card.frontPath : card.backPath!;
      if (isOwner) {
        return cache.ownFace(
          card,
          front: front,
          signedUrl: () => repo.imageUrl(path),
          quotaMb: ref.read(ownCardsQuotaMbProvider),
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

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = '';
    });
    final repo = ref.read(cardsRepositoryProvider);
    try {
      if (!_limitsApply) {
        await _fetchFaces();
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
        if (!mounted) return;
        setState(() => _phase = _Phase.viewing);
        return;
      }
      if (_delivery!.destroyedAt != null) {
        await ref.read(cardMediaCacheProvider).purgeCard(widget.card.id);
        if (!mounted) return;
        setState(() => _phase = _Phase.destroyed);
        return;
      }
      final remaining = _delivery!.remainingViews(widget.card);
      if (remaining != null && remaining <= 0) {
        await ref.read(cardMediaCacheProvider).purgeCard(widget.card.id);
        if (!mounted) return;
        setState(() => _phase = _Phase.exhausted);
        return;
      }

      await _fetchFaces();
      if (!mounted) return;

      // Consomme une vue (1 vue = 1 ouverture) et démarre le budget du recto
      await repo.markViewed(_delivery!.id);
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

  /// Toutes les faces sont épuisées : Hot → destruction ; sinon état des
  /// vues restantes (replay) ou fermeture.
  Future<void> _endSession() async {
    if (_sessionEnded) return;
    _sessionEnded = true;
    _gaugeTimer?.cancel();
    if (widget.card.type == CardType.hot) {
      await _finishHot();
      return;
    }
    _delivery = await ref
        .read(cardsRepositoryProvider)
        .myDelivery(widget.card.id);
    if (!mounted) return;
    final remaining = _delivery?.remainingViews(widget.card);
    if (remaining != null && remaining <= 0) {
      // Plus aucune vue : rien ne doit rester sur l'appareil.
      await ref.read(cardMediaCacheProvider).purgeCard(widget.card.id);
      if (!mounted) return;
      setState(() => _phase = _Phase.exhausted);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _finishHot() async {
    if (_hotFinished || _delivery == null) return;
    _hotFinished = true;
    try {
      await ref.read(cardsRepositoryProvider).finishHotView(_delivery!.id);
    } catch (_) {}
    // Hot : purge immédiate du cache à la fermeture (consigne Jay —
    // empêcher la récupération après coup).
    await ref.read(cardMediaCacheProvider).purgeCard(widget.card.id);
    if (mounted) setState(() => _phase = _Phase.destroyed);
  }

  Future<void> _requestReplay() async {
    try {
      await ref.read(cardsRepositoryProvider).requestReplay(_delivery!.id);
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
    // Hot : quitter l'écran, même avant la fin du temps, détruit la Card —
    // et purge son cache local immédiatement.
    if (_limitsApply &&
        widget.card.type == CardType.hot &&
        !_hotFinished &&
        _delivery != null &&
        _phase == _Phase.viewing) {
      _hotFinished = true;
      ref.read(cardsRepositoryProvider).finishHotView(_delivery!.id);
      ref.read(cardMediaCacheProvider).purgeCard(widget.card.id);
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
    final file = front ? _frontFile! : _backFile!;
    if (_faceIsVideo(front)) {
      return _VideoFace(
        file: file,
        type: type,
        // La vidéo ne joue que lorsque sa face est posée à l'écran
        active: _phase == _Phase.viewing && _settledFront == front,
        // Barre intouchable pour le destinataire sauf accord du créateur ;
        // toujours libre pour l'émetteur et en bibliothèque.
        allowScrub: !_limitsApply || widget.card.scrubbable,
        // En lecture illimitée la vidéo boucle ; en chat elle compte une fois
        loop: !_limitsApply,
        onCompleted: _limitsApply ? () => _markFaceDone(front) : null,
      );
    }
    return _CardFace(file: file, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.card.type;
    final me = ref.watch(currentUserIdProvider);
    // Enregistrable : ses propres cards (Hot comprise, 1/1 exclue — le
    // créateur la rouvre depuis le chat à la place), ou une card reçue
    // marquée sauvegardable par son créateur.
    final isOwner = widget.card.ownerId == me;
    final canSave = isOwner
        ? type != CardType.oneOfOne
        : (widget.card.saveable && type.canBeSaveable);
    final isSaved = ref.watch(isCardSavedProvider(widget.card.id)).value;

    // Jauge visible : face photo posée, à durée limitée, encore vivante
    final showGauge =
        _phase == _Phase.viewing &&
        _limitsApply &&
        widget.card.viewDurationSeconds != null &&
        !_faceIsVideo(_settledFront) &&
        !_faceDone(_settledFront);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: _TypeBadge(type: type),
        actions: [
          if (canSave && _phase == _Phase.viewing)
            IconButton(
              icon: Icon(
                isSaved == true ? Icons.bookmark : Icons.bookmark_border,
              ),
              tooltip: isSaved == true
                  ? 'Retirer de mes Enregistrements'
                  : 'Enregistrer pour moi',
              onPressed: () async {
                final repo = ref.read(cardsRepositoryProvider);
                try {
                  if (isSaved == true) {
                    await repo.unsaveCard(widget.card.id);
                  } else {
                    await repo.saveCard(widget.card.id);
                  }
                  ref.invalidate(isCardSavedProvider(widget.card.id));
                  ref.invalidate(savedCardsProvider);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                  }
                }
              },
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
          icon: Icons.local_fire_department,
          color: type.color,
          message: type == CardType.hot
              ? 'Cette Card Hot a été vue.\nSon contenu a disparu — le container reste bloqué.'
              : 'Cette Card a été détruite.',
        ),
        _Phase.exhausted => _ExhaustedState(
          card: widget.card,
          delivery: _delivery,
          onReplayRequested: _requestReplay,
        ),
        // Mono : face unique non retournable, le jeu d'angle reste
        _Phase.viewing when _backFile == null => Center(
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
      bottomNavigationBar: _phase == _Phase.viewing
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _backFile == null
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

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});
  final CardType type;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: type.gradient,
        border: type.gradient == null
            ? Border.all(color: type.color, width: 2)
            : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        type.tag,
        style: TextStyle(
          color: type.gradient == null ? type.color : Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
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
            'Chargement de la Card…',
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
              'Impossible de charger la Card.\nVérifie ta connexion.',
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
              'Tu as utilisé tous tes visionnages pour cette Card.',
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

/// Cadre commun d'une face : liseré à la couleur du type (dégradé pour
/// Oneshot/BeReal), coins arrondis, fond noir.
class _FaceFrame extends StatelessWidget {
  const _FaceFrame({required this.type, required this.child});
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

/// Face photo : image servie depuis le cache local (préchargée à
/// l'ouverture — plus de réseau ici).
class _CardFace extends StatelessWidget {
  const _CardFace({required this.file, required this.type});
  final File file;
  final CardType type;

  @override
  Widget build(BuildContext context) {
    return _FaceFrame(
      type: type,
      child: Image.file(
        file,
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
  });
  final File file;
  final CardType type;

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
      if (widget.active) _controller.play();
      setState(() {});
    });
  }

  void _onTick() {
    if (!mounted) return;
    final value = _controller.value;
    if (!widget.loop &&
        !_completedFired &&
        value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration) {
      _completedFired = true;
      widget.onCompleted?.call();
    }
    setState(() {}); // rafraîchit la barre de progression
  }

  @override
  void didUpdateWidget(covariant _VideoFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active && _controller.value.isInitialized) {
      widget.active ? _controller.play() : _controller.pause();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _FaceFrame(
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
    return _FaceFrame(
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
